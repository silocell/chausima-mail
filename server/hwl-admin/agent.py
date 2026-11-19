#!/usr/bin/env python3
"""HWL Admin agent: the server side of HWL Admin (maintenance.civilinitiatives.org/hwl/).

Runs as root on HEH-Live, listening on 127.0.0.1:8711 only; Caddy passes https://hehs-live.duckdns.org/hwl-admin/*
to it. Every request must carry a Launchpad sign-in (Supabase access token) for one of the two HWL Admin
accounts. The token's signature is checked here with the server's JWT secret, then the auth server is asked
whether that sign-in is still valid. Only a fixed list of actions exists: no shell, no file browsing.
Everything that changes something is written to /var/log/hwl-admin.log (append-only; the page can read it,
nothing here can delete it).
"""
import base64, hashlib, hmac, json, os, re, subprocess, threading, time, urllib.parse, urllib.request, urllib.error
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

os.environ["TZ"] = "Europe/London"
time.tzset()
ADMINS = {"shivkforindia@gmail.com"}  # shiv@chausima.com removed after the 19 Nov break-in; add back once it is secured
ORIGINS = {"https://admin.chausima.com", "https://maintenance.civilinitiatives.org", "https://civilinitiatives.org"}
SB = os.environ.get("HWL_SB", "/home/opc/supabase")
LOG = os.environ.get("HWL_LOG", "/var/log/hwl-admin.log")
GOTRUE = os.environ.get("HWL_GOTRUE", "http://127.0.0.1:8000")
YACY = "http://127.0.0.1:8090"
SKIP = "/var/lib/hwl-sleep/skip"
STATE = os.environ.get("HWL_STATE", "/var/lib/hwl-admin/state.json")   # master switch + restart screen, read by every Launchpad page


def state_read():
    try:
        return json.load(open(STATE))
    except (OSError, ValueError):
        return {}


def state_write(**kw):
    s = state_read()
    s.update(kw)
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f)
    os.replace(tmp, STATE)
    return s


def state_public():
    s = state_read()
    now = time.time()
    restarting = bool(s.get("restart_kind")) and now < float(s.get("restart_until") or 0)
    return {"lock": bool(s.get("lock")), "msg": str(s.get("lock_msg") or "")[:300], "restarting": restarting,
            "kind": s.get("restart_kind") if restarting else "", "until": int(s.get("restart_until") or 0) if restarting else 0}


def boot_clear():
    """A whole-server restart is over once we're running again after the reboot."""
    s = state_read()
    if s.get("restart_kind") == "server":
        try:
            booted = time.time() - float(open("/proc/uptime").read().split()[0])
        except OSError:
            booted = time.time()
        if booted > float(s.get("restart_at") or 0) or time.time() > float(s.get("restart_until") or 0):
            state_write(restart_kind="", restart_until=0)


# Lockdown keeps only what HWL Admin needs to sign you in (so you can turn it off again); everything else stops.
KEEP_RE = re.compile(r"^(?:supabase[-_.])?(db|auth|kong|envoy)(?:[-_.]\d+)?$")
ROLE = {"db": "db", "auth": "auth", "kong": "gateway", "envoy": "gateway"}


def keep_names(running):
    """The database, sign-in and gateway (kong or envoy) containers. Empty if any of the three is missing."""
    found = {}
    for n in running:
        m = KEEP_RE.match(n)
        if m:
            found[ROLE[m.group(1)]] = n
    return set(found.values()) if len(found) == 3 else set()
SUITE = "cryptpad"
LOCK_LOCK = threading.Lock()


def lockdown_apply(who="system", ip="-"):
    """Stop the Suite gracefully first (it saves what's open), then everything else straight away."""
    with LOCK_LOCK:
        running = [l for l in run(["docker", "ps", "--format", "{{.Names}}"], timeout=20)[0].split() if l]
        stopped = list(state_read().get("lock_stopped") or [])
        if SUITE in running:
            run(["docker", "stop", "-t", "60", SUITE], timeout=120)
            stopped.append(SUITE)
        keep = keep_names(running)
        if not keep:   # never lock you out of HWL Admin: stop only the Suite and leave the rest
            audit(who, ip, "lockdown_stopped", "couldn't find sign-in containers - only the Suite stopped", "failed")
            state_write(lock_stopped=sorted(set(stopped)))
            return
        rest = [n for n in running if n not in keep and n != SUITE]
        if rest:
            run(["docker", "stop", "-t", "2"] + rest, timeout=300)
            stopped += rest
        state_write(lock_stopped=sorted(set(stopped)))
        audit(who, ip, "lockdown_stopped", " ".join(sorted(set(stopped)))[:400])


def lockdown_lift(who, ip):
    with LOCK_LOCK:
        names = list(state_read().get("lock_stopped") or [])
        if names:
            run(["docker", "start"] + names, timeout=600)
        state_write(lock_stopped=[])
        # back to whatever the night/day timetable says right now
        subprocess.run(["/usr/local/bin/hwl-sleep", "tick"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
        audit(who, ip, "lockdown_started_again", " ".join(names)[:400])


def restart_services(who, ip):
    """Restart every running container, wait for the Launchpad's server to answer, then take the screen down."""
    try:
        ids = run(["docker", "ps", "-q"], timeout=20)[0].split()
        out, rc = run(["docker", "restart", "-t", "30"] + ids, timeout=600) if ids else ("", 0)
        for _ in range(60):
            if http_code(GOTRUE + "/auth/v1/health") not in (0, 502, 503, 504):
                break
            time.sleep(5)
        audit(who, ip, "restart_all", "services", "ok" if rc == 0 else "failed")
    finally:
        state_write(restart_kind="", restart_until=0)


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
    except urllib.error.HTTPError as e:
        if e.code >= 500:
            raise PermissionError("The sign-in service is restarting. Try again in a minute.")
        raise PermissionError("Sign in again.")
    except (urllib.error.URLError, OSError):
        raise PermissionError("The sign-in service is restarting. Try again in a minute.")
    return email


def run(cmd, timeout=30):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return r.stdout.strip(), r.returncode


# ---------- Admin code: a secret only Shiv knows, asked for after signing in ----------
# Set on the server with: sudo hwl-admin-pin   (only a scrambled scrypt hash is stored, root-only)
# Two wrong codes within one minute lock code entry for 30 minutes (kept on disk, so a restart doesn't reset it).
PIN_FILE = os.environ.get("HWL_PIN_FILE", "/etc/hwl-admin/pin")
GUARD = os.environ.get("HWL_PIN_GUARD", "/var/lib/hwl-admin/pin-guard.json")
UNLOCK_KEY = os.urandom(32)          # new every start: restarting the agent asks everyone for the code again
UNLOCK_SECS = 30 * 60
LOCK_SECS = 30 * 60
PIN_LOCK = threading.Lock()


class PinNeeded(Exception):
    pass


def pin_hash(pin, salt):
    return hashlib.scrypt(pin.encode(), salt=salt, n=2 ** 14, r=8, p=1, dklen=32)


def pin_check(pin):
    try:
        kind, salt, want = open(PIN_FILE).read().strip().split("$")
    except (OSError, ValueError):
        raise PinNeeded("No admin code is set yet. Set one on the server with: sudo hwl-admin-pin")
    return kind == "scrypt" and hmac.compare_digest(pin_hash(pin, base64.b64decode(salt)), base64.b64decode(want))


def guard_read():
    try:
        return json.load(open(GUARD))
    except (OSError, ValueError):
        return {}


def guard_write(g):
    os.makedirs(os.path.dirname(GUARD), exist_ok=True)
    with open(GUARD + ".tmp", "w") as f:
        json.dump(g, f)
    os.replace(GUARD + ".tmp", GUARD)


def pin_unlock(pin, who, ip):
    with PIN_LOCK:
        g, now = guard_read(), time.time()
        if now < float(g.get("locked_until") or 0):
            mins = int((float(g["locked_until"]) - now) // 60) + 1
            audit(who, ip, "admin_code", "tried while locked", "refused")
            raise PinNeeded("Code entry is locked after wrong codes. Try again in %d minute%s." % (mins, "" if mins == 1 else "s"))
        if pin_check(str(pin or "")[:64]):
            guard_write({"fails": [], "locked_until": 0})
            audit(who, ip, "admin_code", "", "ok")
            exp = int(now + UNLOCK_SECS)
            msg = ("%s|%d" % (who, exp)).encode()
            return base64.urlsafe_b64encode(msg).decode() + "." + hmac.new(UNLOCK_KEY, msg, hashlib.sha256).hexdigest()
        fails = [t for t in (g.get("fails") or []) if now - float(t) < 60] + [now]
        if len(fails) >= 2:
            guard_write({"fails": [], "locked_until": now + LOCK_SECS})
            audit(who, ip, "admin_code", "2 wrong in a minute: locked 30 min", "refused")
            raise PinNeeded("Wrong code. That's 2 wrong in a minute, so code entry is locked for 30 minutes.")
        guard_write({"fails": fails, "locked_until": 0})
        audit(who, ip, "admin_code", "wrong code", "refused")
        raise PinNeeded("Wrong code. One more wrong code within a minute locks it for 30 minutes.")


def unlock_ok(tok, who):
    try:
        b64, sig = tok.split(".")
        msg = base64.urlsafe_b64decode(b64.encode())
        email, exp = msg.decode().rsplit("|", 1)
    except (ValueError, UnicodeDecodeError, base64.binascii.Error):
        return False
    return hmac.compare_digest(sig, hmac.new(UNLOCK_KEY, msg, hashlib.sha256).hexdigest()) and email == who and time.time() < int(exp)


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
    if a == "years":
        return {"years": rest("GET", "signup_years?select=prefix,label,open&order=prefix.desc")}
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
    if a == "year_set":
        prefix = str(body.get("prefix", ""))
        if not re.fullmatch(r"[0-9]{2}", prefix):
            raise ValueError("A year group is the two numbers at the start of the email, like 26.")
        label = str(body.get("label") or "").strip()[:40]
        row = {"prefix": prefix, "open": bool(body.get("open"))}
        if label:
            row["label"] = label
        have = rest("GET", "signup_years?prefix=eq." + prefix + "&select=prefix")
        if have:
            rest("PATCH", "signup_years?prefix=eq." + prefix, row)
        else:
            if not label:
                raise ValueError("Give the new year group a name, like Year 9.")
            rest("POST", "signup_years", row)
        audit(who, ip, a, prefix + (" open" if row["open"] else " closed"))
        return {"years": rest("GET", "signup_years?select=prefix,label,open&order=prefix.desc")}
    if a == "lockdown":
        on = bool(body.get("on"))
        msg = str(body.get("message") or "").strip()[:300]
        if on and str(body.get("confirm", "")).strip().upper() != "LOCKDOWN":
            raise ValueError("Type LOCKDOWN to shut the server down.")
        if on and not keep_names(run(["docker", "ps", "--format", "{{.Names}}"], timeout=20)[0].split()):
            raise ValueError("Can't find the sign-in services (database, auth, gateway), so lockdown would lock you out too. Nothing was changed.")
        if on == bool(state_read().get("lock")):
            return {"state": state_public()}
        state_write(lock=on, lock_msg=msg if on else "", lock_at=time.time() if on else 0)
        audit(who, ip, a, ("on: " + msg) if on else "off")
        threading.Thread(target=lockdown_apply if on else lockdown_lift, args=(who, ip), daemon=True).start()
        return {"state": state_public()}
    if a == "restart_all":
        kind = body.get("kind")
        if kind not in ("services", "server"):
            raise ValueError("Pick services or the whole server.")
        if str(body.get("confirm", "")).strip().upper() != "RESTART":
            raise ValueError("Type RESTART to restart.")
        if state_public()["restarting"]:
            raise ValueError("A restart is already going.")
        if state_read().get("lock"):
            raise ValueError("Lockdown is on - turn it off first.")
        now = time.time()
        state_write(restart_kind=kind, restart_at=now, restart_until=now + (600 if kind == "server" else 420))
        if kind == "server":
            # 20 seconds' grace so every page picks up the restarting screen first
            out, rc = run(["systemd-run", "--unit=hwl-admin-reboot", "--collect", "--on-active=20", "/usr/bin/systemctl", "reboot"], timeout=20)
            if rc != 0:
                state_write(restart_kind="", restart_until=0)
                audit(who, ip, a, kind, "failed")
                raise ValueError("Couldn't schedule the restart.")
            audit(who, ip, a, kind, "in 20 s")
        else:
            threading.Thread(target=restart_services, args=(who, ip), daemon=True).start()
            audit(who, ip, a, kind, "started")
        return {"state": state_public()}
    if a == "state":
        return {"state": state_public()}
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
            self.send_header("Access-Control-Allow-Headers", "authorization, content-type, x-hwl-unlock")
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
        if body.get("action") == "unlock":
            try:
                return self.reply(200, {"unlock": pin_unlock(body.get("code"), who, ip), "minutes": UNLOCK_SECS // 60})
            except PinNeeded as e:
                return self.reply(403, {"error": str(e), "pin": True})
        if not unlock_ok((self.headers.get("X-HWL-Unlock") or "").strip(), who):
            return self.reply(403, {"error": "Enter your admin code.", "pin": True})
        try:
            return self.reply(200, act(body, who, ip))
        except ValueError as e:
            return self.reply(400, {"error": str(e)})
        except Exception as e:
            audit(who, ip, str(body.get("action", ""))[:40], "", "error: " + type(e).__name__)
            return self.reply(500, {"error": "That didn't work: " + type(e).__name__})

    def do_GET(self):
        if self.path.split("?")[0].rstrip("/") in ("/hwl-admin/state", "/state"):
            b = json.dumps(state_public()).encode()   # public on purpose: every Launchpad page reads it
            self.send_response(200)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            return self.wfile.write(b)
        self.reply(404, {"error": "Nothing here."})

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    boot_clear()
    if state_read().get("lock"):
        threading.Thread(target=lockdown_apply, daemon=True).start()
    ThreadingHTTPServer((os.environ.get("HWL_BIND", "127.0.0.1"), int(os.environ.get("HWL_PORT", "8711"))), H).serve_forever()
