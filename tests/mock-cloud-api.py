#!/usr/bin/env python3
"""Minimal Hetzner Cloud v1 / Vultr v2 mock used to test provision.sh.

No credentials are needed and nothing leaves localhost. Every request is
appended to the log file given as the first argument, as one JSON object per
line, so the test can assert what the provisioner actually sent.

    python3 tests/mock-cloud-api.py /tmp/requests.log 18080
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

LOG_PATH = sys.argv[1]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 18080

state = {
    "hetzner": {"ssh_key": None, "firewall": None, "servers": {}},
    "vultr": {"ssh_key": None, "firewall": None, "instances": {}},
}
lock = threading.Lock()


def log(entry):
    with lock, open(LOG_PATH, "a") as fh:
        fh.write(json.dumps(entry) + "\n")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # silence stderr noise
        pass

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return None
        raw = self.rfile.read(length)
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return {"_unparsed": raw.decode(errors="replace")}

    def _send(self, code, payload=None):
        data = b"" if payload is None else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            self.wfile.write(data)

    def _handle(self, method):
        parsed = urlparse(self.path)
        path = parsed.path
        body = self._body()
        log({"method": method, "path": path, "query": parsed.query, "body": body})

        # ------------------------------ Hetzner v1 ------------------------------
        if path == "/v1/images":
            return self._send(200, {"images": [{"id": 114690387, "name": "ubuntu-24.04"}]})
        if path == "/v1/server_types":
            return self._send(200, {"server_types": [
                {"name": "cx23", "cores": 2, "memory": 4, "disk": 40},
                {"name": "cx33", "cores": 4, "memory": 8, "disk": 80},
            ]})
        if path == "/v1/ssh_keys" and method == "GET":
            keys = [] if not state["hetzner"]["ssh_key"] else [state["hetzner"]["ssh_key"]]
            return self._send(200, {"ssh_keys": keys})
        if path == "/v1/ssh_keys" and method == "POST":
            state["hetzner"]["ssh_key"] = {"id": 11, "name": (body or {}).get("name", "key")}
            return self._send(201, {"ssh_key": state["hetzner"]["ssh_key"]})
        if path == "/v1/firewalls" and method == "GET":
            fws = [] if not state["hetzner"]["firewall"] else [state["hetzner"]["firewall"]]
            return self._send(200, {"firewalls": fws})
        if path == "/v1/firewalls" and method == "POST":
            state["hetzner"]["firewall"] = {"id": 21, "name": (body or {}).get("name")}
            return self._send(201, {"firewall": state["hetzner"]["firewall"]})
        if path == "/v1/servers" and method == "POST":
            server = {
                "id": 31,
                "name": (body or {}).get("name"),
                "status": "running",
                "public_net": {"ipv4": {"ip": "203.0.113.50"}},
            }
            state["hetzner"]["servers"][31] = server
            return self._send(201, {"server": server})
        if path.startswith("/v1/servers/"):
            sid = int(path.rsplit("/", 1)[1])
            if method == "GET" and sid in state["hetzner"]["servers"]:
                return self._send(200, {"server": state["hetzner"]["servers"][sid]})
            if method == "DELETE":
                state["hetzner"]["servers"].pop(sid, None)
                return self._send(204)
        if path.startswith("/v1/firewalls/") and method == "DELETE":
            state["hetzner"]["firewall"] = None
            return self._send(204)

        # ------------------------------- Vultr v2 -------------------------------
        if path == "/v2/os":
            return self._send(200, {"os": [
                {"id": 2284, "name": "Ubuntu 24.04 LTS x64"},
                {"id": 1743, "name": "Ubuntu 22.04 LTS x64"},
            ]})
        if path == "/v2/plans":
            return self._send(200, {"plans": [
                {"id": "vc2-2c-4gb", "vcpu_count": 2, "ram": 4096, "disk": 80},
            ]})
        if path == "/v2/ssh-keys" and method == "GET":
            keys = [] if not state["vultr"]["ssh_key"] else [state["vultr"]["ssh_key"]]
            return self._send(200, {"ssh_keys": keys})
        if path == "/v2/ssh-keys" and method == "POST":
            state["vultr"]["ssh_key"] = {"id": "k1", "name": (body or {}).get("name")}
            return self._send(201, {"ssh_key": state["vultr"]["ssh_key"]})
        if path == "/v2/firewalls/group" and method == "POST":
            state["vultr"]["firewall"] = {"id": "g1"}
            return self._send(201, {"firewall_group": {"id": "g1"}})
        if path.startswith("/v2/firewalls/group/") and path.endswith("/rules"):
            return self._send(201, {"rule": {}})
        if path == "/v2/instances" and method == "POST":
            inst = {
                "id": "i1",
                "label": (body or {}).get("label"),
                "status": "active",
                "main_ip": "203.0.113.60",
            }
            state["vultr"]["instances"]["i1"] = inst
            return self._send(202, {"instance": inst})
        if path.startswith("/v2/instances/"):
            iid = path.rsplit("/", 1)[1]
            if method == "GET" and iid in state["vultr"]["instances"]:
                return self._send(200, {"instance": state["vultr"]["instances"][iid]})
            if method == "DELETE":
                state["vultr"]["instances"].pop(iid, None)
                return self._send(204)
        if path.startswith("/v2/firewalls/group/") and method == "DELETE":
            state["vultr"]["firewall"] = None
            return self._send(204)

        self._send(404, {"error": {"message": f"mock: no route {method} {path}"}})

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_DELETE(self):
        self._handle("DELETE")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
