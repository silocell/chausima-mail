#!/usr/bin/env python3
"""Chausima Mail: info@ complaint log.

Every new email in info@chausima.com's Inbox is copied to a log address
(LOG_TO, e.g. an AOL inbox) as a fresh email from info@: who sent it, to whom,
when, the subject and the full text, with the original attached as
original.eml. The original is deleted from info@ once the log copy has been
delivered (Stalwart's delivery status says "yes") and at least DELETE_AFTER
seconds (210 = 3.5 minutes) have passed. If delivery fails it is retried, and
after 3 failures the email is left in info@ with the keyword $logfailed.

Config: /etc/chausima-logger.env  (INFO_USER, INFO_PASS, LOG_TO). Never printed.
State:  /var/lib/chausima-logger/state.json
"""
import base64, json, os, sys, time, urllib.request, urllib.error

BASE = os.environ.get("MAIL_BASE", "https://mail.chausima.com")
STATE = "/var/lib/chausima-logger/state.json"
DELETE_AFTER = int(os.environ.get("DELETE_AFTER", "210"))
EVERY = int(os.environ.get("EVERY", "30"))
USING = ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail", "urn:ietf:params:jmap:submission"]
SKIP_FROM = ("mailer-daemon", "postmaster")
TAG = "[info@ log]"

def env():
    cfg = {}
    with open("/etc/chausima-logger.env") as f:
        for line in f:
            if "=" in line and not line.startswith("#"):
                k, v = line.rstrip("\n").split("=", 1); cfg[k.strip()] = v
    return cfg

class Jmap:
    def __init__(self, user, pw):
        self.auth = "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()
        s = self.get(BASE + "/jmap/session")
        if not s.get("username"): raise SystemExit("info@ sign-in failed (check INFO_PASS)")
        self.api = BASE + "/jmap/"; self.acct = s["primaryAccounts"]["urn:ietf:params:jmap:mail"]
    def _req(self, url, data=None):
        r = urllib.request.Request(url, data=data, headers={"Authorization": self.auth, "Content-Type": "application/json", "Accept": "application/json"})
        with urllib.request.urlopen(r, timeout=30) as resp: return json.load(resp)
    def get(self, url): return self._req(url)
    def call(self, calls):
        d = self._req(self.api, json.dumps({"using": USING, "methodCalls": calls}).encode())
        out = {}
        for name, res, tag in d["methodResponses"]:
            if name == "error": raise RuntimeError(f"{tag}: {res.get('type')} {res.get('description','')}")
            out[tag] = res
        return out

def addrs(a): return ", ".join((f'{x.get("name")} <{x["email"]}>' if x.get("name") else x["email"]) for x in (a or []))

def load_state():
    try:
        with open(STATE) as f: return json.load(f)
    except Exception: return {}

def save_state(st):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f: json.dump(st, f)
    os.replace(tmp, STATE)

def say(*a): print(time.strftime("%H:%M:%S"), *a, flush=True)

def cycle(j, cfg, st):
    r = j.call([["Mailbox/get", {"accountId": j.acct, "properties": ["role"]}, "m"],
                ["Identity/get", {"accountId": j.acct}, "i"]])
    boxes = {b["role"]: b["id"] for b in r["m"]["list"] if b.get("role")}
    ident = next((i for i in r["i"]["list"] if i["email"].lower() == cfg["INFO_USER"].lower()), r["i"]["list"][0])
    inbox, sent = boxes["inbox"], boxes.get("sent")

    # 1. log new mail
    r = j.call([["Email/query", {"accountId": j.acct, "filter": {"inMailbox": inbox, "notKeyword": "$logsent"}, "sort": [{"property": "receivedAt", "isAscending": True}], "limit": 20}, "q"],
                ["Email/get", {"accountId": j.acct, "#ids": {"resultOf": "q", "name": "Email/query", "path": "/ids"},
                               "properties": ["from", "to", "cc", "subject", "receivedAt", "blobId", "textBody", "htmlBody", "bodyValues", "keywords"],
                               "fetchTextBodyValues": True, "fetchHTMLBodyValues": True, "maxBodyValueBytes": 500000}, "g"]])
    for m in r["g"]["list"]:
        frm = (m.get("from") or [{}])[0].get("email", "").lower()
        subj = m.get("subject") or "(no subject)"
        if frm.split("@")[0] in SKIP_FROM or subj.startswith(TAG) or "$logfailed" in (m.get("keywords") or {}):
            continue
        vals = m.get("bodyValues") or {}
        text = "\n".join(vals.get(p["partId"], {}).get("value", "") for p in (m.get("textBody") or []))
        if not text.strip():
            import re, html
            raw = "\n".join(vals.get(p["partId"], {}).get("value", "") for p in (m.get("htmlBody") or []))
            text = html.unescape(re.sub(r"<[^>]+>", " ", re.sub(r"(?is)<(script|style).*?</\1>", "", raw)))
        body = (f"From:     {addrs(m.get('from'))}\nTo:       {addrs(m.get('to'))}\n" + (f"Cc:       {addrs(m.get('cc'))}\n" if m.get("cc") else "") +
                f"Received: {m.get('receivedAt')}\nSubject:  {subj}\n\n{'-'*60}\n\n{text.strip()}\n\n{'-'*60}\nThe original email is attached as original.eml.\n")
        log = {"mailboxIds": {sent: True} if sent else {}, "keywords": {"$seen": True},
               "from": [{"name": "Chausima Mail log", "email": ident["email"]}], "to": [{"email": cfg["LOG_TO"]}],
               "subject": f"{TAG} {subj}", "bodyValues": {"b": {"value": body}}, "textBody": [{"partId": "b", "type": "text/plain"}],
               "attachments": [{"blobId": m["blobId"], "type": "message/rfc822", "name": "original.eml", "disposition": "attachment"}]}
        res = j.call([["Email/set", {"accountId": j.acct, "create": {"k": log}}, "e"],
                      ["EmailSubmission/set", {"accountId": j.acct, "create": {"s": {"identityId": ident["id"], "emailId": "#k"}},
                                               "onSuccessDestroyEmail": ["#s"]}, "x"]])
        if res["e"].get("notCreated") or res["x"].get("notCreated"):
            say("could not send log for", m["id"], res["e"].get("notCreated") or res["x"].get("notCreated")); continue
        sub = res["x"]["created"]["s"]["id"]
        j.call([["Email/set", {"accountId": j.acct, "update": {m["id"]: {"keywords/$logsent": True}}}, "u"]])
        prev = st.get(m["id"], {})
        st[m["id"]] = {"sub": sub, "at": time.time(), "tries": prev.get("tries", 0) + 1}
        save_state(st); say("logged", m["id"], "->", cfg["LOG_TO"])

    # 2. delete originals once their log copy is delivered and 3.5 minutes have passed
    due = {eid: v for eid, v in st.items() if time.time() - v["at"] >= DELETE_AFTER}
    if not due: return
    r = j.call([["EmailSubmission/get", {"accountId": j.acct, "ids": [v["sub"] for v in due.values()], "properties": ["deliveryStatus", "undoStatus"]}, "s"]])
    subs = {s["id"]: s for s in r["s"]["list"]}
    for eid, v in due.items():
        s = subs.get(v["sub"])
        status = ((s or {}).get("deliveryStatus") or {}).get(cfg["LOG_TO"].lower()) or ((s or {}).get("deliveryStatus") or {}).get(cfg["LOG_TO"]) or {}
        delivered = status.get("delivered")
        if delivered == "yes":
            j.call([["Email/set", {"accountId": j.acct, "destroy": [eid]}, "d"]])
            del st[eid]; save_state(st); say("deleted original", eid, "(log delivered)")
        elif delivered == "no":
            if v["tries"] >= 3:
                j.call([["Email/set", {"accountId": j.acct, "update": {eid: {"keywords/$logfailed": True, "keywords/$logsent": None}}}, "u"]])
                del st[eid]; say("gave up on", eid, "- left in info@ with $logfailed")
            else:
                j.call([["Email/set", {"accountId": j.acct, "update": {eid: {"keywords/$logsent": None}}}, "u"]])
                v["at"] = time.time(); say("log bounced, will retry", eid)
            save_state(st)
        elif s is None and time.time() - v["at"] > 6 * 3600:
            say("no delivery record for", eid, "- leaving it in info@"); del st[eid]; save_state(st)

def main():
    cfg = env()
    for k in ("INFO_USER", "INFO_PASS", "LOG_TO"):
        if not cfg.get(k): raise SystemExit(f"{k} missing in /etc/chausima-logger.env")
    st = load_state(); j = None
    while True:
        try:
            j = j or Jmap(cfg["INFO_USER"], cfg["INFO_PASS"])
            cycle(j, cfg, st)
        except urllib.error.HTTPError as e:
            say("server said", e.code); j = None
        except Exception as e:
            say("error:", type(e).__name__, str(e)[:200]); j = None
        if "--once" in sys.argv: break
        time.sleep(EVERY)

if __name__ == "__main__": main()
