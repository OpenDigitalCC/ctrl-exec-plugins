#!/usr/bin/env python3
"""Local stand-in for the ctrl-exec API used by test/run.sh.

It checks credentials the way the real API does with a token-checking auth
hook: POST /run needs the token in the body, GET /status/<reqid> needs
"Authorization: Bearer <token>" (otherwise 404, like the real status auth
denial). Every request is appended to the log file ("run script=<name>
args=<json>" or "status auth=[<header>]").

POST /run executes the request on this machine:
  agent-file-receive   runs the real receiver script (argv from "args") and
                       returns its exit/stdout/stderr, exactly what the
                       executor would hand back for that run
  agent-file-transfer  stands in for the sending agent: builds a small
                       tar.gz and sends it to --dest with openssl s_client
Mode "sync" answers with the result inline; mode "async" answers with a
reqid only and serves the result from GET /status/<reqid>.

Writes its port to the port file once listening.
Usage: stub-api.py <token> <port-file> <log-file> <receive-script> [sync|async]
"""
import json, os, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN, PORTFILE, LOG, RECV = sys.argv[1:5]
MODE = sys.argv[5] if len(sys.argv) > 5 else "sync"
RESULTS, LOCK, SEQ = {}, threading.Lock(), [0]


def log(line):
    with LOCK:
        with open(LOG, "a") as f:
            f.write(line + "\n")


def run_script(script, args):
    if script == "agent-file-receive":
        p = subprocess.run([RECV] + args, capture_output=True, text=True,
                           stdin=subprocess.DEVNULL, timeout=60)
        return p.returncode, p.stdout, p.stderr
    if script == "agent-file-transfer":
        dest = args[args.index("--dest") + 1]
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "payload.txt"), "w") as f:
                f.write("hello\n")
            arc = os.path.join(d, "a.tar.gz")
            subprocess.run(["tar", "-czf", arc, "-C", d, "payload.txt"], check=True)
            with open(arc, "rb") as f:
                p = subprocess.run(
                    ["openssl", "s_client", "-connect", dest, "-quiet",
                     "-no_ign_eof", "-nocommands"],
                    stdin=f, capture_output=True, timeout=60)
            return p.returncode, "size:%d\n" % os.path.getsize(arc), ""
    return 127, "", "unknown script " + script


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        if not TOKEN or body.get("token") != TOKEN:
            self._send(200, {"ok": False, "error": "bad credentials", "code": 2})
            return
        script, args = body.get("script", ""), body.get("args", [])
        log("run script=%s args=%s" % (script, json.dumps(args)))
        code, out, err = run_script(script, args)
        with LOCK:
            SEQ[0] += 1
            reqid = "r%d" % SEQ[0]
        res = [{"host": body["hosts"][0], "exit": code, "stdout": out, "stderr": err}]
        if MODE == "async":
            RESULTS[reqid] = res
            self._send(200, {"ok": True, "reqid": reqid, "mode": "async"})
        else:
            self._send(200, {"ok": True, "reqid": reqid, "results": res})

    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        log("status auth=[%s]" % auth)
        reqid = self.path.rsplit("/", 1)[-1]
        if auth != "Bearer " + TOKEN or not TOKEN or reqid not in RESULTS:
            self._send(404, {"ok": False, "error": "not found"})
            return
        self._send(200, {"ok": True, "reqid": reqid, "mode": "async",
                         "complete": True, "results": RESULTS[reqid]})


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(PORTFILE, "w").write(str(srv.server_port))
srv.serve_forever()
