#!/usr/bin/env python3
"""Keystone-auth reverse proxy for an OpenStack Ironic API (e.g. OpenMetal).

The KOG rest-dynamic-controller speaks plain HTTP and cannot do Keystone token
exchange/refresh. This proxy authenticates with clouds.yaml (OS_CLOUD), discovers the
baremetal endpoint from the catalog, and forwards every request with a fresh X-Auth-Token
(keystoneauth refreshes it automatically) plus the Ironic microversion header. The operator
points at this proxy instead of Ironic directly - same pattern as the local noauth+nginx setup.

Env:
  OS_CLOUD             cloud name in clouds.yaml (default: openstack)
  OS_INTERFACE         endpoint interface (default: public)
  IRONIC_ENDPOINT      override the discovered baremetal endpoint (optional)
  IRONIC_API_VERSION   default microversion if the client doesn't send one (default: 1.81)
  LISTEN_PORT          default 6385
"""
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import openstack

CLOUD = os.environ.get("OS_CLOUD", "openstack")
INTERFACE = os.environ.get("OS_INTERFACE", "public")
MICRO = os.environ.get("IRONIC_API_VERSION", "1.81")
PORT = int(os.environ.get("LISTEN_PORT", "6385"))

conn = openstack.connect(cloud=CLOUD)
SESS = conn.session
ENDPOINT = os.environ.get("IRONIC_ENDPOINT") or SESS.get_endpoint(
    service_type="baremetal", interface=INTERFACE
)
ENDPOINT = ENDPOINT.rstrip("/")
print(f"[proxy] cloud={CLOUD} baremetal endpoint={ENDPOINT} microversion>={MICRO}", flush=True)

_HOP = {"content-length", "transfer-encoding", "content-encoding", "connection", "keep-alive"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _proxy(self):
        try:
            length = int(self.headers.get("Content-Length", 0) or 0)
            body = self.rfile.read(length) if length else None
            url = ENDPOINT + self.path  # self.path includes the query string
            headers = {
                "X-OpenStack-Ironic-API-Version": self.headers.get(
                    "X-OpenStack-Ironic-API-Version", MICRO
                ),
                "Accept": "application/json",
            }
            ct = self.headers.get("Content-Type")
            if ct:
                headers["Content-Type"] = ct
            # SESS.request injects (and refreshes) X-Auth-Token automatically.
            r = SESS.request(url, self.command, headers=headers, data=body, raise_exc=False)
            data = r.content or b""
            self.send_response(r.status_code)
            for k, v in r.headers.items():
                if k.lower() not in _HOP:
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if data:
                self.wfile.write(data)
        except Exception as exc:  # surface proxy errors to the client/logs
            msg = f'{{"error_message": "proxy error: {exc}"}}'.encode()
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)
            print(f"[proxy] ERROR {self.command} {self.path}: {exc}", file=sys.stderr, flush=True)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = _proxy

    def log_message(self, fmt, *args):
        print("[proxy] " + (fmt % args), flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
