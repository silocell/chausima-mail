#!/usr/bin/env python3
"""HWL Admin agent: the server side of HWL Admin (maintenance.civilinitiatives.org/hwl/).

Runs as root on HEH-Live, listening on 127.0.0.1:8711 only; Caddy passes https://hehs-live.duckdns.org/hwl-admin/*
to it. Every request must carry a Launchpad sign-in (Supabase access token) for one of the two HWL Admin
accounts. The token's signature is checked here with the server's JWT secret, then the auth server is asked
whether that sign-in is still valid. Only a fixed list of actions exists: no shell, no file browsing.
Everything that changes something is written to /var/log/hwl-admin.log (append-only; the page can read it,
nothing here can delete it).
"""
import base64, hashlib, hmac, json, os, re, subprocess, time, urllib.parse, urllib.request, urllib.error
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

os.environ["TZ"] = "Europe/London"
time.tzset()
ADMINS = {"shiv@chausima.com", "shivkforindia@gmail.com"}
ORIGINS = {"https://admin.chausima.com", "https://maintenance.civilinitiatives.org", "https://civilinitiatives.org"}
SB = os.environ.get("HWL_SB", "/home/opc/supabase")
LOG = os.environ.get("HWL_LOG", "/var/log/hwl-admin.log")
GOTRUE = os.environ.get("HWL_GOTRUE", "http://127.0.0.1:8000")
YACY = "http://127.0.0.1:8090"
SKIP = "/var/lib/hwl-sleep/skip"


def env(path, key):
    try:
        for line in open(path):
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return ""


def secrets():
    e = os.path.join(SB, ".env")
    return env(e, "JWT_SECRET"), env(e, "ANON_KEY"), env(e, "SERVICE_ROLE_KEY")


def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def check_token(tok):
    """Returns the admin's email, or raises PermissionError."""
    jwt_secret, anon, _ = secrets()
    try:
        h, p, sig = tok.split(".")
        head = json.loads(b64d(h))
        if head.get("alg") != "HS256":
            raise ValueError
        good = hmac.new(jwt_secret.encode(), (h + "." + p).encode(), hashlib.sha256).digest()
        if not jwt_secret or not hmac.compare_digest(good, b64d(sig)):
            raise ValueError
        claims = json.loads(b64d(p))
    except Exception:
        raise PermissionError("Sign in again.")
    if claims.get("exp", 0) < time.time() or claims.get("role") != "authenticated":
        raise PermissionError("Your sign-in has expired. Sign in again.")
    email = str(claims.get("email", "")).lower()
    if email not in ADMINS:
        raise PermissionError("HWL Admin isn't for this account.")
    # still a live sign-in? (catches signed-out or deleted accounts)
    req = urllib.request.Request(GOTRUE + "/auth/v1/user", headers={"apikey": anon, "Authorization": "Bearer " + tok})
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            if str(json.load(r).get("email", "")).lower() != email:
                raise PermissionError("Sign in again.")
    except urllib.error.HTTPError:
        raise PermissionError("Sign in again.")
    return email


def run(cmd, timeout=30):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return r.stdout.strip(), r.returncode


def audit(who, ip, action, detail="", result="ok"):
    line = json.dumps({"at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S"), "who": who, "ip": ip,
                       "action": action, "detail": detail, "result": result}, ensure_ascii=False)
    with open(LOG, "a") as f:
        f.write(line + "\n")


def containers():
    out, _ = run(["docker", "ps", "-a", "--format", "{{.Names}}\t{{.State}}\t{{.Status}}"])
    rows = []
    for l in out.splitlines():
        n, st, s = (l.split("\t") + ["", ""])[:3]
        rows.append({"name": n, "state": st, "status": s})
    return sorted(rows, key=lambda r: r["name"])


def http_code(url):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, method="GET"), timeout=8) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return 0


def yacy_get(path, params=None):
    pw = env("/etc/chausima-yacy.env", "YACY_ADMIN_PASS")
    url = YACY + path + ("?" + urllib.parse.urlencode(params) if params else "")
    mgr = urllib.request.HTTPPasswordMgrWithDefaultRealm()
    mgr.add_password(None, YACY, "admin", pw)
    op = urllib.request.build_opener(urllib.request.HTTPDigestAuthHandler(mgr))
    with op.open(url, timeout=15) as r:
        return r.read().decode("utf-8", "replace")


def status():
    load = open("/proc/loadavg").read().split()[:3]
    mem = {}
    for l in open("/proc/meminfo"):
        k, v = l.split(":")
        mem[k] = int(v.split()[0])
    st = os.statvfs("/mnt/launchpad-data") if os.path.isdir("/mnt/launchpad-data") else os.statvfs("/")
    phase, _ = run(["/usr/local/bin/hwl-sleep", "now"])
    up = float(open("/proc/uptime").read().split()[0])
    docs = None
    try:
        j = json.loads(yacy_get("/api/status_p.json"))
        docs = j.get("index", {}).get("size") or j.get("index")
    except Exception:
        pass
    skip = open(SKIP).read().strip() if os.path.exists(SKIP) else ""
    return {
        "cores": os.cpu_count(), "load": load,
        "mem_gb": round(mem.get("MemTotal", 0) / 1048576, 1), "mem_free_gb": round(mem.get("MemAvailable", 0) / 1048576, 1),
        "disk_gb": round(st.f_blocks * st.f_frsize / 1e9), "disk_free_gb": round(st.f_bavail * st.f_frsize / 1e9),
        "uptime_h": round(up / 3600, 1), "mode": phase, "skip_tonight": skip,
        "checks": {
            "Launchpad sign-in": http_code(GOTRUE + "/auth/v1/health") in (200, 401),
            "Chausima Mail page": http_code("https://mail.chausima.com/") == 200,
            "HWL Search": http_code(YACY + "/yacysearch.json?query=test&maximumRecords=1") == 200,
        },
        "yacy_docs": docs, "containers": containers(),
    }


def users(page=1):
    _, _, svc = secrets()
    req = urllib.request.Request(GOTRUE + "/auth/v1/admin/users?per_page=200&page=%d" % page,
                                 headers={"apikey": svc, "Authorization": "Bearer " + svc})
    with urllib.request.urlopen(req, timeout=15) as r:
        j = json.load(r)
    out = []
    for u in j.get("users", []):
        out.append({"id": u["id"], "email": u.get("email"), "created": (u.get("created_at") or "")[:16],
                    "last": (u.get("last_sign_in_at") or "")[:16],
                    "how": ",".join(sorted({i.get("provider") for i in (u.get("identities") or [])})) or "password"})
    return sorted(out, key=lambda u: u["last"] or "", reverse=True)


def delete_user(uid, confirm, who):
    if not re.fullmatch(r"[0-9a-f-]{36}", uid or ""):
        raise ValueError("Unknown account.")
    target = next((u for u in users() if u["id"] == uid), None)
    if not target:
        raise ValueError("That account isn't there any more.")
    if (confirm or "").strip().lower() != (target["email"] or "").lower():
        raise ValueError("Type the account's email exactly to confirm.")
    if (target["email"] or "").lower() in ADMINS:
        raise ValueError("HWL Admin accounts can't be deleted from here.")
    _, _, svc = secrets()
    req = urllib.request.Request(GOTRUE + "/auth/v1/admin/users/" + uid, method="DELETE",
                                 headers={"apikey": svc, "Authorization": "Bearer " + svc})
    urllib.request.urlopen(req, timeout=15).read()
    return target["email"]


def rest(method, path, body=None):
    """The database's REST door (PostgREST), as the server itself."""
    _, _, svc = secrets()
    req = urllib.request.Request(GOTRUE + "/rest/v1/" + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"apikey": svc, "Authorization": "Bearer " + svc, "content-type": "application/json", "Prefer": "return=representation"})
    with urllib.request.urlopen(req, timeout=15) as r:
        t = r.read().decode() or "[]"
    return json.loads(t)


KEEP_CHZ = {"shiv"}   # the owner's own Chausima account can't be deleted or turned off from here


def chz_find(uid):
    if not re.fullmatch(r"[0-9a-f-]{36}", uid or ""):
        raise ValueError("Unknown account.")
    rows = rest("GET", "chausima_accounts?select=id,username,name,disabled&id=eq." + uid)
    if not rows:
        raise ValueError("That account isn't there any more.")
    return rows[0]


SPEEDS = {"gentle": 120, "normal": 400, "fast": 1000, "max": 1500}


def act(body, who, ip):
    a = body.get("action")
    if a == "status":
        return status()
    if a == "users":
        return {"users": users(int(body.get("page") or 1))}
    if a == "chz_users":
        rows = rest("GET", "chausima_accounts?select=id,username,name,created_at,last_login,disabled&order=created_at.desc&limit=1000")
        return {"users": [{"id": x["id"], "username": x["username"], "name": x["name"], "created": (x.get("created_at") or "")[:16],
                           "last": (x.get("last_login") or "")[:16], "disabled": bool(x.get("disabled"))} for x in rows]}
    if a == "audit":
        try:
            lines = open(LOG).read().splitlines()[-300:]
        except OSError:
            lines = []
        return {"entries": [json.loads(l) for l in reversed(lines) if l.startswith("{")]}
    if a == "logs":
        name = body.get("name", "")
        if name not in {c["name"] for c in containers()}:
            raise ValueError("Unknown service.")
        r = subprocess.run(["docker", "logs", "--tail", "120", name], capture_output=True, text=True, timeout=20)
        return {"text": (r.stdout + r.stderr)[-20000:]}
    # ---- everything below changes something, and is logged ----
    if a == "restart":
        name = body.get("name", "")
        if name not in {c["name"] for c in containers()}:
            raise ValueError("Unknown service.")
        out, rc = run(["docker", "restart", "-t", "30", name], timeout=90)
        audit(who, ip, a, name, "ok" if rc == 0 else "failed")
        return {"done": rc == 0}
    if a == "mode":
        to = body.get("to")
        if to not in ("tick", "maint", "sleep", "deep", "wake"):
            raise ValueError("Unknown mode.")
        subprocess.Popen(["/usr/local/bin/hwl-sleep", to], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        audit(who, ip, a, to, "started")
        return {"started": True}
    if a == "skip_tonight":
        on = bool(body.get("on"))
        os.makedirs(os.path.dirname(SKIP), exist_ok=True)
        if on:
            t = time.localtime()
            night = time.strftime("%Y-%m-%d", t if t.tm_hour >= 12 else time.localtime(time.time() - 86400))
            open(SKIP, "w").write(night)
        elif os.path.exists(SKIP):
            os.remove(SKIP)
        audit(who, ip, a, "on" if on else "off")
        return {"skip_tonight": on}
    if a == "yacy_speed":
        lvl = body.get("level")
        if lvl not in SPEEDS:
            raise ValueError("Unknown speed.")
        yacy_get("/Crawler_p.html", {"crawlingPerformance": "custom", "customPPM": SPEEDS[lvl]})
        audit(who, ip, a, "%s (%d pages/min)" % (lvl, SPEEDS[lvl]))
        return {"ppm": SPEEDS[lvl]}
    if a == "yacy_crawl":
        url = str(body.get("url", "")).strip()
        if not re.fullmatch(r"https?://[A-Za-z0-9.-]+\.[A-Za-z]{2,}(/[^\s]*)?", url):
            raise ValueError("Give a full web address, like https://www.bbc.co.uk/bitesize")
        depth = max(0, min(4, int(body.get("depth") or 2)))
        host = urllib.parse.urlparse(url).hostname
        yacy_get("/Crawler_p.html", {"crawlingDomMaxPages": 2000, "range": "domain", "crawlingstart": "Start", "crawlingMode": "url",
                                       "crawlingURL": url, "crawlingDepth": depth, "indexText": "on", "indexMedia": "on",
                                       "crawlingQ": "on", "storeHTCache": "on", "crawlOrder": "on", "mustmatch": ".*" + re.escape(host) + ".*"})
        audit(who, ip, a, "%s depth %d" % (url, depth))
        return {"queued": url}
    if a == "chz_disable":
        x = chz_find(body.get("id"))
        if x["username"] in KEEP_CHZ:
            raise ValueError("Your own Chausima account can't be turned off from here.")
        off = bool(body.get("off"))
        rest("PATCH", "chausima_accounts?id=eq." + x["id"], {"disabled": off})
        audit(who, ip, a, "%s@chausima.com %s" % (x["username"], "off" if off else "on"))
        return {"disabled": off}
    if a == "chz_delete":
        x = chz_find(body.get("id"))
        if x["username"] in KEEP_CHZ:
            raise ValueError("Your own Chausima account can't be deleted from here.")
        if (body.get("confirm") or "").strip().lower().replace("@chausima.com", "") != x["username"]:
            raise ValueError("Type the username exactly to confirm.")
        rest("DELETE", "chausima_accounts?id=eq." + x["id"])
        audit(who, ip, a, x["username"] + "@chausima.com")
        return {"deleted": x["username"]}
    if a == "delete_user":
        email = delete_user(body.get("id"), body.get("confirm"), who)
        audit(who, ip, a, email)
        return {"deleted": email}
    raise ValueError("Unknown action.")


class H(BaseHTTPRequestHandler):
    server_version = "hwl-admin"

    def cors(self):
        o = self.headers.get("Origin", "")
        if o in ORIGINS:
            self.send_header("Access-Control-Allow-Origin", o)
            self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Headers", "authorization, content-type")
            self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")

    def reply(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.cors()
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_OPTIONS(self):
        self.send_response(204)
        self.cors()
        self.end_headers()

    def do_POST(self):
        ip = (self.headers.get("X-Forwarded-For") or self.client_address[0]).split(",")[0].strip()
        if self.path.rstrip("/") not in ("/hwl-admin/api", "/api"):
            return self.reply(404, {"error": "Nothing here."})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(min(n, 20000)) or b"{}")
        except Exception:
            return self.reply(400, {"error": "Bad request."})
        tok = (self.headers.get("Authorization") or "").removeprefix("Bearer ").strip()
        try:
            who = check_token(tok)
        except PermissionError as e:
            if tok:
                audit("?", ip, "refused", str(body.get("action", ""))[:40], str(e))
            return self.reply(403, {"error": str(e)})
        try:
            return self.reply(200, act(body, who, ip))
        except ValueError as e:
            return self.reply(400, {"error": str(e)})
        except Exception as e:
            audit(who, ip, str(body.get("action", ""))[:40], "", "error: " + type(e).__name__)
            return self.reply(500, {"error": "That didn't work: " + type(e).__name__})

    def do_GET(self):
        self.reply(404, {"error": "Nothing here."})

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer((os.environ.get("HWL_BIND", "127.0.0.1"), int(os.environ.get("HWL_PORT", "8711"))), H).serve_forever()
