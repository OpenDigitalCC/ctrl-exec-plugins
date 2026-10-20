#!/usr/bin/env python3
"""Local stand-in for the ctrl-exec API used by test/run.sh.

POST /run answers ok with a reqid. GET /status/<reqid> answers a finished
synchronous-shaped record only when "Authorization: Bearer <token>" matches
the token given on argv; otherwise it answers 404 like the real API's status
auth denial. Every status request's Authorization header is appended to the
log file. Writes its port to the port file once listening.
Usage: stub-api.py <token> <port-file> <log-file>
"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN, PORTFILE, LOG = sys.argv[1], sys.argv[2], sys.argv[3]
STDOUT = "fingerprint:AA:BB:CC\nreceived:5\n"

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self._send(200, {"ok": True, "reqid": "r1", "results": [
            {"host": "h", "exit": 0, "stdout": "size:5\n", "stderr": ""}]})
    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        with open(LOG, "a") as f:
            f.write("status auth=[%s]\n" % auth)
        if auth != "Bearer " + TOKEN or not TOKEN:
            self._send(404, {"ok": False, "error": "not found"})
            return
        self._send(200, {"ok": True, "reqid": "r1", "mode": "sync", "complete": True,
                         "results": [{"host": "h", "exit": 0, "stdout": STDOUT, "stderr": ""}]})

srv = HTTPServer(("127.0.0.1", 0), H)
open(PORTFILE, "w").write(str(srv.server_port))
srv.serve_forever()
