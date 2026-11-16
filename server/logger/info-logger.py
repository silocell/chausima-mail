#!/usr/bin/env python3
"""Chausima Mail: info@ complaint log.

Every new email in info@chausima.com's Inbox is copied to a log address
(LOG_TO, e.g. an AOL inbox) as a fresh email from info@: who sent it, to whom,
when, the subject and the full text, with the original attached as
original.eml. The original is deleted from info@ once the log copy has been
delivered (Stalwart's delivery status says "yes") and at least DELETE_AFTER
seconds (210 = 3.5 minutes) have passed. If delivery fails it is retried, and
after 3 failures the email is left in info@ with the keyword $logfailed.

Replies sent from info@ are logged too (marked "Reply sent"), but stay in Sent.

Weekly wash: every WASH_DAYS (7) days the whole info@ mailbox (every folder) is
emptied, except emails whose log hasn't been delivered yet. Then a note is put
in the Inbox for the AI that answers info@, saying when the wash happened and
where older mail is, and a "weekly wash done" line goes to the log address.

Help desk: before an Inbox email is deleted, the Launchpad help desk must have
made its ticket for it (helpdesk_tickets.mail_id). The logger asks the help
desk to sync straight after logging, so this normally takes seconds.

Mail log: every logged email, delivery result and weekly wash is also written
to the Launchpad table public.mail_log, which the Maintenance panel shows.
Email text in that table is cleared after BODY_DAYS (7), like help desk tickets;
the full copy stays in the log mailbox.

Config: /etc/chausima-logger.env  (INFO_USER, INFO_PASS, LOG_TO). Never printed.
Supabase URL and service key are read from /home/opc/supabase/.env.
State:  /var/lib/chausima-logger/state.json
"""
import base64, json, os, sys, time, urllib.request, urllib.error, urllib.parse

BASE = os.environ.get("MAIL_BASE", "https://mail.chausima.com")
STATE = "/var/lib/chausima-logger/state.json"
DELETE_AFTER = int(os.environ.get("DELETE_AFTER", "210"))
EVERY = int(os.environ.get("EVERY", "30"))
USING = ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail", "urn:ietf:params:jmap:submission"]
SKIP_FROM = ("mailer-daemon", "postmaster")
TAG = "[info@ log]"
NOTE = "[Chausima note]"
WASH_DAYS = float(os.environ.get("WASH_DAYS", "7"))
BODY_DAYS = int(os.environ.get("BODY_DAYS", "7"))
SUPA_ENV = "/home/opc/supabase/.env"

class Supa:
    """Talks to the Launchpad database (PostgREST) and functions with the service key."""
    def __init__(self):
        e = {}
        try:
            with open(SUPA_ENV) as f:
                for line in f:
                    if "=" in line and not line.startswith("#"):
                        k, v = line.rstrip("\n").split("=", 1); e[k] = v.strip().strip('"')
        except OSError: pass
        self.url = (e.get("SUPABASE_PUBLIC_URL") or e.get("API_EXTERNAL_URL") or "https://hehs-live.duckdns.org").rstrip("/")
        self.key = e.get("SERVICE_ROLE_KEY", "")
        self.ok = bool(self.key)
    def _req(self, method, path, body=None, prefer=None):
        h = {"apikey": self.key, "Authorization": "Bearer " + self.key, "Content-Type": "application/json"}
        if prefer: h["Prefer"] = prefer
        r = urllib.request.Request(self.url + path, method=method, headers=h, data=json.dumps(body).encode() if body is not None else None)
        with urllib.request.urlopen(r, timeout=30) as resp:
            t = resp.read(); return json.loads(t) if t else None
    def insert(self, row):
        if not self.ok: return None
        try: return (self._req("POST", "/rest/v1/mail_log", row, "return=representation") or [{}])[0].get("id")
        except Exception as e: say("mail_log insert failed:", str(e)[:120]); return None
    def update(self, rid, row):
        if not (self.ok and rid): return
        try: self._req("PATCH", f"/rest/v1/mail_log?id=eq.{rid}", row)
        except Exception as e: say("mail_log update failed:", str(e)[:120])
    def trim_bodies(self):
        if not self.ok: return
        cut = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - BODY_DAYS * 86400))
        try: self._req("PATCH", f"/rest/v1/mail_log?at=lt.{cut}&body=not.is.null", {"body": None})
        except Exception as e: say("mail_log trim failed:", str(e)[:120])
    def has_ticket(self, mail_id):
        if not self.ok: return True   # no database access: don't block deleting
        try: return bool(self._req("GET", f"/rest/v1/helpdesk_tickets?select=id&mail_id=eq.{urllib.parse.quote(mail_id)}&limit=1"))
        except Exception: return False
    def helpdesk_sync(self):
        if not self.ok: return
        try: self._req("POST", "/functions/v1/helpdesk", {"action": "sync"})
        except Exception as e: say("help desk sync failed:", str(e)[:120])
SUPA = None

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
    before = len(pending(st))
    for folder, kind in ((inbox, "in"), (sent, "out")):
        if folder: log_folder(j, cfg, st, ident, folder, kind, sent)
    if len(pending(st)) != before: SUPA.helpdesk_sync()
    if time.time() - st.get("_last_trim", 0) > 3600: SUPA.trim_bodies(); st["_last_trim"] = time.time(); save_state(st)
    deliver_and_delete(j, cfg, st)
    maybe_wash(j, cfg, st, ident, inbox, sent)

def log_folder(j, cfg, st, ident, folder, kind, sent):
    r = j.call([["Email/query", {"accountId": j.acct, "filter": {"inMailbox": folder, "notKeyword": "$logsent"}, "sort": [{"property": "receivedAt", "isAscending": True}], "limit": 20}, "q"],
                ["Email/get", {"accountId": j.acct, "#ids": {"resultOf": "q", "name": "Email/query", "path": "/ids"},
                               "properties": ["from", "to", "cc", "subject", "receivedAt", "blobId", "textBody", "htmlBody", "bodyValues", "keywords"],
                               "fetchTextBodyValues": True, "fetchHTMLBodyValues": True, "maxBodyValueBytes": 500000}, "g"]])
    for m in r["g"]["list"]:
        frm = (m.get("from") or [{}])[0].get("email", "").lower()
        subj = m.get("subject") or "(no subject)"
        if frm.split("@")[0] in SKIP_FROM or subj.startswith(TAG) or subj.startswith(NOTE) or "$logfailed" in (m.get("keywords") or {}) or "$draft" in (m.get("keywords") or {}):
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
               "subject": f"{TAG} {'Reply sent: ' if kind == 'out' else ''}{subj}", "bodyValues": {"b": {"value": body}}, "textBody": [{"partId": "b", "type": "text/plain"}],
               "attachments": [{"blobId": m["blobId"], "type": "message/rfc822", "name": "original.eml", "disposition": "attachment"}]}
        res = j.call([["Email/set", {"accountId": j.acct, "create": {"k": log}}, "e"],
                      ["EmailSubmission/set", {"accountId": j.acct, "create": {"s": {"identityId": ident["id"], "emailId": "#k"}},
                                               "onSuccessDestroyEmail": ["#s"]}, "x"]])
        if res["e"].get("notCreated") or res["x"].get("notCreated"):
            say("could not send log for", m["id"], res["e"].get("notCreated") or res["x"].get("notCreated")); continue
        sub = res["x"]["created"]["s"]["id"]
        j.call([["Email/set", {"accountId": j.acct, "update": {m["id"]: {"keywords/$logsent": True}}}, "u"]])
        prev = st.get(m["id"], {})
        rid = prev.get("row") or SUPA.insert({"kind": kind, "mail_id": m["id"], "mail_from": addrs(m.get("from"))[:300], "mail_to": addrs(m.get("to"))[:300],
                                             "subject": subj[:300], "body": text.strip()[:20000], "received_at": m.get("receivedAt"), "aol_status": "sending"})
        st[m["id"]] = {"sub": sub, "at": time.time(), "tries": prev.get("tries", 0) + 1, "keep": kind == "out", "row": rid,
                       "ticket": kind == "in" and frm != cfg["INFO_USER"].lower()}   # the help desk skips mail from info@ itself
        save_state(st); say("logged", kind, m["id"], "->", cfg["LOG_TO"])

def pending(st): return {k: v for k, v in st.items() if not k.startswith("_")}

def deliver_and_delete(j, cfg, st):
    """Delete originals once their log copy is delivered and 3.5 minutes have passed."""
    due = {eid: v for eid, v in pending(st).items() if time.time() - v["at"] >= DELETE_AFTER}
    if not due: return
    r = j.call([["EmailSubmission/get", {"accountId": j.acct, "ids": [v["sub"] for v in due.values()], "properties": ["deliveryStatus", "undoStatus"]}, "s"]])
    subs = {s["id"]: s for s in r["s"]["list"]}
    for eid, v in due.items():
        s = subs.get(v["sub"])
        status = ((s or {}).get("deliveryStatus") or {}).get(cfg["LOG_TO"].lower()) or ((s or {}).get("deliveryStatus") or {}).get(cfg["LOG_TO"]) or {}
        delivered = status.get("delivered")
        if delivered == "yes":
            if not v.get("keep"):
                if v.get("ticket", True) and not SUPA.has_ticket(eid):
                    if not v.get("synced"): SUPA.helpdesk_sync(); v["synced"] = True; save_state(st)
                    continue   # wait until the help desk has its ticket
                j.call([["Email/set", {"accountId": j.acct, "destroy": [eid]}, "d"]]); say("deleted original", eid, "(log delivered, ticket made)")
            SUPA.update(v.get("row"), {"aol_status": "delivered", **({} if v.get("keep") else {"deleted_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})})
            del st[eid]; save_state(st)
        elif delivered == "no":
            if v["tries"] >= 3:
                j.call([["Email/set", {"accountId": j.acct, "update": {eid: {"keywords/$logfailed": True, "keywords/$logsent": None}}}, "u"]])
                SUPA.update(v.get("row"), {"aol_status": "failed"})
                del st[eid]; say("gave up on", eid, "- left in info@ with $logfailed")
            else:
                j.call([["Email/set", {"accountId": j.acct, "update": {eid: {"keywords/$logsent": None}}}, "u"]])
                v["at"] = time.time(); SUPA.update(v.get("row"), {"aol_status": "retrying"}); say("log bounced, will retry", eid)
            save_state(st)
        elif s is None and time.time() - v["at"] > 6 * 3600:
            say("no delivery record for", eid, "- leaving it in info@"); del st[eid]; save_state(st)

def send_plain(j, ident, to, subject, body, mailbox=None, flag=False, submit=True):
    obj = {"mailboxIds": {mailbox: True} if mailbox else {}, "keywords": {"$flagged": True} if flag else {"$seen": True},
           "from": [{"name": "Chausima Mail", "email": ident["email"]}], "to": [{"email": to}], "subject": subject,
           "bodyValues": {"b": {"value": body}}, "textBody": [{"partId": "b", "type": "text/plain"}]}
    calls = [["Email/set", {"accountId": j.acct, "create": {"k": obj}}, "e"]]
    if submit:
        calls.append(["EmailSubmission/set", {"accountId": j.acct, "create": {"s": {"identityId": ident["id"], "emailId": "#k"}}, "onSuccessDestroyEmail": ["#s"]}, "x"])
    return j.call(calls)

def maybe_wash(j, cfg, st, ident, inbox, sent):
    now = time.time()
    last = st.get("_last_wash")
    if last is None:
        st["_last_wash"] = now; save_state(st); say("weekly wash clock started"); return
    if now - last < WASH_DAYS * 86400: return
    keep = set(pending(st))  # logs not delivered yet
    ids, pos = [], 0
    while True:
        r = j.call([["Email/query", {"accountId": j.acct, "position": pos, "limit": 500}, "q"]])
        got = r["q"].get("ids", []); ids += got; pos += len(got)
        if len(got) < 500: break
    # never wash mail that hasn't been logged yet
    r = j.call([["Email/get", {"accountId": j.acct, "ids": ids, "properties": ["keywords", "mailboxIds", "subject"]}, "g"]]) if ids else {"g": {"list": []}}
    gone = []
    for m in r["g"]["list"]:
        k, boxes = m.get("keywords") or {}, m.get("mailboxIds") or {}
        unlogged = (inbox in boxes or (sent and sent in boxes)) and "$logsent" not in k and "$draft" not in k and not (m.get("subject") or "").startswith(NOTE)
        if m["id"] in keep or unlogged: continue
        gone.append(m["id"])
    for i in range(0, len(gone), 200):
        j.call([["Email/set", {"accountId": j.acct, "destroy": gone[i:i + 200]}, "d"]])
    when = time.strftime("%A %d %B %Y at %H:%M UTC", time.gmtime(now))
    note = (f"Note for whoever answers info@chausima.com (including the AI helper):\n\n"
            f"This mailbox was washed clean on {when}. {len(gone)} emails were removed from every folder.\n"
            f"Nothing was lost: every email received and every reply sent before then was copied to the log mailbox ({cfg['LOG_TO']}).\n\n"
            f"If someone mentions an earlier email you can't find here, it was archived in the weekly wash. "
            f"Tell them politely it has been archived and ask them to send the details again.\n\n"
            f"The next wash is due around {time.strftime('%A %d %B %Y', time.gmtime(now + WASH_DAYS * 86400))}.")
    send_plain(j, ident, ident["email"], f"{NOTE} Inbox washed on {time.strftime('%d %b %Y', time.gmtime(now))}", note, mailbox=inbox, flag=True, submit=False)
    send_plain(j, ident, cfg["LOG_TO"], f"{TAG} Weekly wash done: {len(gone)} emails removed", note)
    SUPA.insert({"kind": "wash", "subject": f"Weekly wash: {len(gone)} emails removed", "body": note, "aol_status": "sent"})
    st["_last_wash"] = now; save_state(st); say("weekly wash:", len(gone), "emails removed, note left in Inbox")

def main():
    cfg = env()
    for k in ("INFO_USER", "INFO_PASS", "LOG_TO"):
        if not cfg.get(k): raise SystemExit(f"{k} missing in /etc/chausima-logger.env")
    global SUPA
    SUPA = Supa()
    if not SUPA.ok: say("no Launchpad service key found - mail_log and help desk checks are off")
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
