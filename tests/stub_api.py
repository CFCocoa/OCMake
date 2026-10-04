#!/usr/bin/env python3
"""HTTP stub for OCMake's GitHub API error-handling tests.

Serves deterministic status codes so the 401/403/429 paths can be exercised without
burning the real rate limit. Starts on an ephemeral port, runs the CMake test driver
against it, and exits with the driver's status.

Routes:
  /release        200 + a release JSON that echoes the Authorization header it saw
  /status/<code>  that status code
  /hits/<prefix>  200 + {"count": n} requests seen whose path starts with /<prefix>
"""
import http.server
import json
import subprocess
import sys
import threading
from collections import Counter

HITS = Counter()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        HITS[self.path] += 1
        if self.path.startswith("/status/"):
            try:
                code = int(self.path.rsplit("/", 1)[1])
            except ValueError:
                code = 500
            # Real GitHub sends a JSON body here; CMake discards it on error, which is
            # exactly the behaviour the production code has to cope with.
            self._send(code, {"message": "stub error"})
        elif self.path.startswith("/release"):
            self._send(200, {
                "tag_name": "v1.2.3",
                "assets": [{
                    "name": "Thing-1.2.3-RELEASE.zip",
                    "browser_download_url": "https://example.invalid/Thing-1.2.3-RELEASE.zip",
                }],
                "seen_auth": self.headers.get("Authorization", "<none>"),
            })
        elif self.path.startswith("/hits/"):
            prefix = "/" + self.path.split("/hits/", 1)[1]
            n = sum(c for p, c in HITS.items() if p.startswith(prefix))
            self._send(200, {"count": n})
        else:
            self._send(404, {"message": "Not Found"})

    def log_message(self, *args):
        pass


class Server(http.server.ThreadingHTTPServer):
    # curl closes keep-alive connections abruptly; that is normal, not a failure.
    def handle_error(self, request, client_address):
        pass


def main():
    if len(sys.argv) < 2:
        print("usage: stub_api.py <command> [args...]  ('{PORT}' is substituted)", file=sys.stderr)
        return 2
    server = Server(("127.0.0.1", 0), Handler)
    port = server.server_port
    threading.Thread(target=server.serve_forever, daemon=True).start()
    cmd = [a.replace("{PORT}", str(port)) for a in sys.argv[1:]]
    try:
        return subprocess.call(cmd)
    finally:
        server.shutdown()


if __name__ == "__main__":
    sys.exit(main())
