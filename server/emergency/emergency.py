#!/usr/bin/env python3
"""HEH-Live emergency page: a command runner plus an AI helper, for when Shiv can't use Cloud Shell, his
phone or HWL Admin. Runs as its own service (hwl-emergency, 127.0.0.1:8712), separate from HWL Admin, so
lockdown, restarts and hwl-recover never stop it; it restarts only on its daily timer.

Protection:
  - lives at a secret 24-character address (/etc/hwl-admin/runner-path); every other address says "Nothing here"
  - signing in needs the recovery passphrase AND the admin code together (both stored as scrypt hashes)
  - 2 wrong sign-ins in a row lock it for 16 hours, for everyone, kept on disk (clear: sudo hwl-admin-pin --unlock)
  - a sign-in lasts 10 minutes, from the same internet address only
  - every command is logged (append-only) with time and address; commands stop after 60 seconds
  - the AI only suggests commands; nothing runs until Shiv presses Run
"""
import base64, hashlib, hmac, json, os, subprocess, threading, time, urllib.request, urllib.error
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

os.environ.setdefault("TZ", "Europe/London"); time.tzset()
PORT = int(os.environ.get("HWL_EMERGENCY_PORT", "8712"))
PATH_FILE = os.environ.get("HWL_RUNNER_PATH", "/etc/hwl-admin/runner-path")
PIN_FILE = os.environ.get("HWL_PIN_FILE", "/etc/hwl-admin/pin")
REC_FILE = os.environ.get("HWL_REC_FILE", "/etc/hwl-admin/recover")
GUARD = os.environ.get("HWL_EMERGENCY_GUARD", "/var/lib/hwl-emergency/guard.json")
LOG = os.environ.get("HWL_EMERGENCY_LOG", "/var/log/hwl-emergency.log")
ADMIN_LOG = os.environ.get("HWL_LOG", "/var/log/hwl-admin.log")
GUIDE = os.environ.get("HWL_GUIDE", os.path.join(os.path.dirname(os.path.abspath(__file__)), "guide.md"))
SB_ENV = os.environ.get("HWL_SB_ENV", "/home/opc/supabase/.env")
LOCK_SECS = 16 * 3600
SESSION_SECS = 10 * 60
KEY = os.urandom(32)
GLOCK = threading.Lock()


def now_s():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def log(ip, what, detail="", result="ok"):
    line = json.dumps({"at": now_s(), "who": "emergency", "ip": ip, "action": what, "detail": detail[:300], "result": result})
    for p in (LOG, ADMIN_LOG):
        try:
            with open(p, "a") as f:
                f.write(line + "\n")
        except OSError:
            pass


def secret_path():
    try:
        p = open(PATH_FILE).read().strip()
        return p if len(p) >= 20 and p.isalnum() else None
    except OSError:
        return None


def hash_ok(path, value):
    try:
        kind, salt, want = open(path).read().strip().split("$")
    except (OSError, ValueError):
        return None
    got = hashlib.scrypt(value.encode(), salt=base64.b64decode(salt), n=2 ** 14, r=8, p=1, dklen=32)
    return kind == "scrypt" and hmac.compare_digest(got, base64.b64decode(want))


def guard():
    try:
        return json.load(open(GUARD))
    except (OSError, ValueError):
        return {}


def guard_save(g):
    os.makedirs(os.path.dirname(GUARD), exist_ok=True)
    with open(GUARD + ".tmp", "w") as f:
        json.dump(g, f)
    os.replace(GUARD + ".tmp", GUARD)


class Refused(Exception):
    pass


def sign_in(pw, code, ip):
    with GLOCK:
        g, t = guard(), time.time()
        if t < float(g.get("locked_until") or 0):
            h = int((float(g["locked_until"]) - t) // 3600)
            log(ip, "emergency_sign_in", "tried while locked", "refused")
            raise Refused("Locked after 2 wrong tries. It opens again in about %d hour%s, or unlock it from Cloud Shell: sudo hwl-admin-pin --unlock" % (h + 1, "" if h == 0 else "s"))
        a, b = hash_ok(REC_FILE, str(pw or "")[:128]), hash_ok(PIN_FILE, str(code or "")[:64])
        if a is None or b is None:
            raise Refused("The recovery passphrase or admin code isn't set up on the server yet.")
        if a and b:
            guard_save({"wrong": 0, "locked_until": 0})
            log(ip, "emergency_sign_in")
            exp = int(t + SESSION_SECS)
            msg = ("%s|%d" % (ip, exp)).encode()
            return base64.urlsafe_b64encode(msg).decode() + "." + hmac.new(KEY, msg, hashlib.sha256).hexdigest()
        wrong = int(g.get("wrong") or 0) + 1
        if wrong >= 2:
            guard_save({"wrong": 0, "locked_until": t + LOCK_SECS})
            log(ip, "emergency_sign_in", "2 wrong in a row: locked 16 hours", "refused")
            raise Refused("Wrong. That's 2 wrong in a row, so this page is locked for 16 hours.")
        guard_save({"wrong": wrong, "locked_until": 0})
        log(ip, "emergency_sign_in", "wrong passphrase or code", "refused")
        raise Refused("Wrong. One more wrong try locks this page for 16 hours.")


def session_ok(tok, ip):
    try:
        b64, sig = str(tok).split(".")
        msg = base64.urlsafe_b64decode(b64.encode())
        tip, exp = msg.decode().rsplit("|", 1)
    except Exception:
        return False
    return hmac.compare_digest(sig, hmac.new(KEY, msg, hashlib.sha256).hexdigest()) and tip == ip and time.time() < int(exp)


def run_cmd(cmd, ip):
    cmd = str(cmd or "").strip()[:4000]
    if not cmd:
        return {"out": "", "rc": 0}
    log(ip, "emergency_run", cmd)
    try:
        p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=60,
                           env={"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "HOME": "/root", "TZ": "Europe/London", "LANG": "C.UTF-8"})
        out, rc = (p.stdout or "") + (p.stderr or ""), p.returncode
    except subprocess.TimeoutExpired as e:
        out, rc = ((e.stdout or b"").decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")) + "\n(stopped after 60 seconds)", 124
    if len(out) > 20000:
        out = "(showing the last part)\n" + out[-20000:]
    return {"out": out, "rc": rc}


def env_key(name):
    """The same keys Launchpad AI uses: from the Supabase settings file, else from the running functions service."""
    for path in (SB_ENV, "/home/opc/supabase/volumes/functions/.env"):
        try:
            for line in open(path):
                if line.startswith(name + "="):
                    v = line.split("=", 1)[1].strip().strip('"')
                    if v:
                        return v
        except OSError:
            pass
    try:
        v = subprocess.run(["docker", "exec", "supabase-edge-functions", "printenv", name], capture_output=True, text=True, timeout=10).stdout.strip()
        if v:
            return v
    except Exception:
        pass
    return os.environ.get(name, "")


def snapshot():
    def sh(c):
        try:
            return subprocess.run(["bash", "-c", c], capture_output=True, text=True, timeout=15).stdout[-3000:]
        except Exception:
            return "(couldn't read)"
    return ("Time now: " + now_s() + "\n\n## docker ps -a\n" + sh("docker ps -a --format '{{.Names}}  {{.Status}}'") +
            "\n## lockdown/restart state\n" + sh("cat /var/lib/hwl-admin/state.json") +
            "\n\n## night timetable\n" + sh("hwl-sleep now 2>/dev/null | head -3") +
            "\n## admin code / passphrase\n" + sh("hwl-admin-pin --status 2>&1") +
            "\n## last HWL Admin actions\n" + sh("tail -8 /var/log/hwl-admin.log | cut -c1-220"))


def ask_ai(history):
    try:
        guide = open(GUIDE).read()
    except OSError:
        guide = "(guide missing)"
    system = guide + "\n\n# Live snapshot of the server, taken just now\n" + snapshot()
    msgs = [{"role": m.get("role"), "content": str(m.get("content", ""))[:4000]} for m in history[-8:] if m.get("role") in ("user", "assistant")]
    if not msgs or msgs[-1]["role"] != "user":
        return "Ask me something first."
    key = env_key("ANTHROPIC_API_KEY")
    if key:
        try:
            req = urllib.request.Request("https://api.anthropic.com/v1/messages", method="POST",
                                         data=json.dumps({"model": "claude-sonnet-5-5", "max_tokens": 1200, "system": system, "messages": msgs}).encode(),
                                         headers={"x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as r:
                d = json.load(r)
            return "".join(b.get("text", "") for b in d.get("content", []) if b.get("type") == "text") or "(no answer)"
        except Exception as e:
            fallback = "Claude didn't answer (%s), so this is from Groq:\n\n" % type(e).__name__
    else:
        fallback = ""
    gk = env_key("GROQ_API_KEY")
    if not gk:
        return "No AI key found on the server, so the AI can't answer. You can still run commands."
    try:
        req = urllib.request.Request("https://api.groq.com/openai/v1/chat/completions", method="POST",
                                     data=json.dumps({"model": "openai/gpt-oss-120b", "max_tokens": 1200,
                                                      "messages": [{"role": "system", "content": system}] + msgs}).encode(),
                                     headers={"Authorization": "Bearer " + gk, "content-type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            d = json.load(r)
        return fallback + d["choices"][0]["message"]["content"]
    except Exception as e:
        return "The AI couldn't answer right now (%s). You can still run commands, for example hwl-recover." % type(e).__name__


PAGE = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "page.html")).read() if os.path.exists(os.path.join(os.path.dirname(os.path.abspath(__file__)), "page.html")) else "<p>page missing</p>"


class H(BaseHTTPRequestHandler):
    def ip(self):
        return (self.headers.get("X-Forwarded-For") or self.client_address[0]).split(",")[0].strip()

    def send(self, code, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(code)
        for k, v in (("Content-Type", ctype + "; charset=utf-8"), ("Cache-Control", "no-store"), ("X-Frame-Options", "DENY"),
                     ("X-Robots-Tag", "noindex, nofollow"), ("Referrer-Policy", "no-referrer"), ("X-Content-Type-Options", "nosniff"),
                     ("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")):
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def where(self):
        sp = secret_path()
        parts = self.path.split("?")[0].strip("/").split("/")
        if not sp or len(parts) < 2 or parts[0] != "hwl-emergency" or not hmac.compare_digest(parts[1], sp):
            return None
        return parts[2] if len(parts) > 2 else ""

    def do_GET(self):
        if self.where() != "":
            return self.send(404, "Nothing here.", "text/plain")
        self.send(200, PAGE, "text/html")

    def do_POST(self):
        w = self.where()
        if w not in ("login", "run", "ask"):
            return self.send(404, "Nothing here.", "text/plain")
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(min(n, 64000)) or b"{}")
        except Exception:
            return self.send(400, {"error": "Bad request."})
        ip = self.ip()
        if w == "login":
            try:
                return self.send(200, {"tok": sign_in(body.get("pw"), body.get("code"), ip), "minutes": SESSION_SECS // 60})
            except Refused as e:
                return self.send(403, {"error": str(e)})
        if not session_ok(body.get("tok"), ip):
            return self.send(403, {"error": "Signed out (10 minutes passed, or your internet address changed). Sign in again.", "signin": True})
        if w == "run":
            return self.send(200, run_cmd(body.get("cmd"), ip))
        log(ip, "emergency_ask", str((body.get("history") or [{}])[-1].get("content", ""))[:200])
        return self.send(200, {"answer": ask_ai(body.get("history") or [])})

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
