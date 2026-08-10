#!/usr/bin/env python3
"""
Healthcheck server for AgentCore Runtime.
Serves /ping on port 8080 while the ACP wrapper runs as the shell command.
"""

import http.server
import threading
import os
import sys


class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/ping":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"healthy"}')
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # suppress access logs


def run_health_server():
    port = int(os.environ.get("HEALTH_PORT", "8080"))
    server = http.server.HTTPServer(("0.0.0.0", port), HealthHandler)
    print(f"Health server listening on :{port}", file=sys.stderr)
    server.serve_forever()


if __name__ == "__main__":
    # Run health server in background
    health_thread = threading.Thread(target=run_health_server, daemon=True)
    health_thread.start()

    # Block forever (AgentCore invokes the shell command separately)
    import signal
    signal.pause()
