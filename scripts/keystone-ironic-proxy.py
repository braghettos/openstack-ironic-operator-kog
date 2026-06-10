#!/usr/bin/env python3
"""Keystone-auth reverse proxy for an OpenStack Ironic API (any deployment).

The KOG rest-dynamic-controller speaks plain HTTP and cannot do Keystone token
exchange/refresh. This proxy authenticates with clouds.yaml (OS_CLOUD), discovers the
baremetal endpoint from the catalog, and forwards every request with a fresh X-Auth-Token
(keystoneauth refreshes it automatically) plus the Ironic microversion header. The operator
points at this proxy instead of Ironic directly - same pattern as the local noauth+nginx setup.

Env:
  OS_CLOUD             cloud name in clouds.yaml (default: openstack)
  OS_INTERFACE         endpoint interface (default: public)
  IRONIC_ENDPOINT      override the discovered baremetal endpoint (optional)
  IRONIC_API_VERSION   default microversion when the client doesn't send one (default: 1.99).
                       1.99 covers parent_node (1.83+) and other recent Node fields; bump if
                       you need newer features. The proxy passes through whatever the client
                       sends; the default only applies on missing/empty headers.
  LISTEN_PORT          default 6385
"""
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import openstack

CLOUD = os.environ.get("OS_CLOUD", "openstack")
INTERFACE = os.environ.get("OS_INTERFACE", "public")
MICRO = os.environ.get("IRONIC_API_VERSION", "1.99")
PORT = int(os.environ.get("LISTEN_PORT", "6385"))

conn = openstack.connect(cloud=CLOUD)
SESS = conn.session
ENDPOINT = os.environ.get("IRONIC_ENDPOINT") or SESS.get_endpoint(
    service_type="baremetal", interface=INTERFACE
)
ENDPOINT = ENDPOINT.rstrip("/")
print(f"[proxy] cloud={CLOUD} baremetal endpoint={ENDPOINT} microversion>={MICRO}", flush=True)

_HOP = {"content-length", "transfer-encoding", "content-encoding", "connection", "keep-alive"}

# Resource endpoints Ironic accepts PATCH on. We translate plain JSON bodies to RFC-6902.
# Extend as we add support (allocations, deploy_templates, conductors are read-only or use
# different verbs; ports + nodes + portgroups are the main PATCH-able resources).
_PATCH_TRANSLATE_PATHS = (
    re.compile(r"^/v1/nodes/[^/]+/?$"),
    re.compile(r"^/v1/ports/[^/]+/?$"),
    re.compile(r"^/v1/portgroups/[^/]+/?$"),
)

# Ironic node fields that are LOCKED in certain provision states. Sending a PATCH op
# touching one of these while the node is in a forbidden state causes Ironic to roll back
# the WHOLE patch (PATCH is atomic). We drop these ops on the floor when the state doesn't
# permit them, so unrelated ops in the same body still succeed.
# Source: Ironic's API state-machine error messages (see e.g. PatchValidation).
# Empty allowed set means "always permitted" (key not in map).
_NODE_FIELD_ALLOWED_STATES = {
    "resource_class": {"enroll", "manageable", "available", "inspecting", "inspect wait"},
    # instance_info: NOT `active`. Ironic accepts PATCH on instance_info while active but
    # it doesn't trigger a redeploy — Ironic's metadata flips silently and the blade keeps
    # running the OLD image. The chart's transition-rebuild handles image swaps via
    # `target: rebuild`, but the instance_info PATCH coordination with that flow is still
    # an open design question (see README "Lifecycle" section). Leaving the gate as-is
    # until the rebuild-with-new-image flow is properly designed end-to-end.
    "instance_info": {"available", "manageable", "enroll"},
    "instance_uuid": {"available", "active"},
    "driver_info":   {"enroll", "manageable", "available", "inspecting", "inspect wait", "active"},
    "driver":        {"enroll", "manageable"},
}

# Fields whose value as seen in the GET response is NOT a reliable comparator — Ironic
# masks/munges them on read. Generating a "replace" op every reconcile against the masked
# read value would create phantom drift. We never emit ops for these keys; if you really
# need to change them, send an explicit PATCH outside the translator.
_NODE_PHANTOM_DRIFT_KEYS = {
    # driver_info password fields are returned as "******" — diff vs spec ALWAYS fires.
    "redfish_password", "ipmi_password", "ssh_password", "snmp_auth_password",
    "snmp_priv_password", "drac_password", "ilo_password", "irmc_password",
}


def _diff_to_json_patch(current, desired, path="", *, current_state=None, top_level=True):
    """Return an RFC-6902 patch list to mutate `current` toward `desired`.

    Recurses into nested objects (driver_info, instance_info, properties, extra).
    Arrays and scalars are replaced as a unit (no LCS / element-level patching).
    Explicit `null` in `desired` removes the key from `current`. Missing keys in
    `desired` are LEFT ALONE (merge semantics, not overwrite-with-undefined).

    `current_state` (only used at top level) is the node's provision_state, used to drop
    ops on fields locked by the state machine. `top_level` is False for recursive calls.
    """
    ops = []
    cur = current if isinstance(current, dict) else {}
    des = desired if isinstance(desired, dict) else {}
    for key, des_val in des.items():
        # Drop fields known to drift phantom-style on read (masked passwords).
        if key in _NODE_PHANTOM_DRIFT_KEYS:
            continue
        # State-gate top-level keys: if the state doesn't permit changes to this field,
        # skip generating any op for it (and any nested op underneath it).
        if top_level and current_state is not None and key in _NODE_FIELD_ALLOWED_STATES:
            if current_state not in _NODE_FIELD_ALLOWED_STATES[key]:
                continue
        sub = f"{path}/{key.replace('~', '~0').replace('/', '~1')}"
        if des_val is None:
            if key in cur:
                ops.append({"op": "remove", "path": sub})
            continue
        cur_val = cur.get(key)
        if isinstance(des_val, dict) and isinstance(cur_val, dict):
            ops.extend(_diff_to_json_patch(
                cur_val, des_val, sub,
                current_state=current_state, top_level=False))
            continue
        if cur_val == des_val:
            continue
        if key in cur:
            ops.append({"op": "replace", "path": sub, "value": des_val})
        else:
            ops.append({"op": "add", "path": sub, "value": des_val})
    return ops


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _read_body(self):
        # The KOG rest-dynamic-controller (Go http client) sends write bodies with
        # Transfer-Encoding: chunked (no Content-Length). BaseHTTPRequestHandler does
        # not de-chunk, so reading Content-Length alone yields an empty body (Ironic
        # then 400s with "'driver' is a required property") and the leftover chunk bytes
        # corrupt the keep-alive connection. Handle both framings explicitly.
        te = (self.headers.get("Transfer-Encoding") or "").lower()
        if "chunked" in te:
            chunks = []
            while True:
                size_line = self.rfile.readline().split(b";", 1)[0].strip()
                if not size_line:
                    continue
                size = int(size_line, 16)
                if size == 0:
                    self.rfile.readline()  # consume the trailing CRLF after the last chunk
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.read(2)  # consume the CRLF after each chunk
            return b"".join(chunks)
        length = int(self.headers.get("Content-Length", 0) or 0)
        return self.rfile.read(length) if length else None

    def _proxy(self):
        try:
            body = self._read_body()
            url = ENDPOINT + self.path  # self.path includes the query string
            # KOG's `findby` on Node does `GET /v1/nodes` and matches client-side by name.
            # By default Ironic's list excludes child nodes (those with parent_node set),
            # so a blade under an enclosure is invisible -> KOG thinks it doesn't exist ->
            # tries POST -> 409 forever. Force include_children=true on the list endpoint.
            if self.command == "GET" and self.path.startswith("/v1/nodes") and \
               not self.path.startswith("/v1/nodes/") and \
               "include_children" not in self.path:
                sep = "&" if "?" in self.path else "?"
                url = ENDPOINT + self.path + sep + "include_children=true"
            # Microversion: prefer the client's value, fall back to MICRO when missing OR
            # empty. KOG's rest-dynamic-controller can emit the header with an empty value
            # (configurationField wired but unresolved); Ironic rejects empty mv with 406.
            client_mv = (self.headers.get("X-OpenStack-Ironic-API-Version") or "").strip()
            headers = {
                "X-OpenStack-Ironic-API-Version": client_mv or MICRO,
                "Accept": "application/json",
            }
            ct = self.headers.get("Content-Type")
            if ct:
                headers["Content-Type"] = ct
            # PATCH translator: Ironic only accepts RFC-6902 JSON-Patch for updates, but
            # KOG/RDC emits a plain JSON body (merge-style). When we see a PATCH on a
            # supported Ironic resource and the body isn't already a JSON-Patch array, GET
            # the current resource, diff against the request body, and rewrite the body to
            # an RFC-6902 op list. This unlocks the `update` verb in our Node/Port RestDefs.
            if self.command == "PATCH" and body and \
               any(p.match(self.path) for p in _PATCH_TRANSLATE_PATHS):
                try:
                    desired = json.loads(body)
                except Exception:
                    desired = None
                if isinstance(desired, dict):  # not already a patch list
                    cur_get_headers = {
                        "X-OpenStack-Ironic-API-Version": client_mv or MICRO,
                        "Accept": "application/json",
                    }
                    g = SESS.request(url, "GET", headers=cur_get_headers, raise_exc=False)
                    if g.status_code == 200:
                        try:
                            current = g.json()
                        except Exception:
                            current = {}
                        # Pass the node's provision_state in so the diff can drop ops on
                        # state-locked fields (resource_class on `active`, instance_info on
                        # `cleaning`, etc.) — Ironic's PATCH is atomic, one forbidden op
                        # rolls the WHOLE patch back.
                        cur_state = (current.get("provision_state") if isinstance(current, dict) else None)
                        patch_ops = _diff_to_json_patch(current, desired, current_state=cur_state)
                        body = json.dumps(patch_ops).encode()
                        headers["Content-Type"] = "application/json-patch+json"
                        print(f"[proxy] PATCH translator: {self.path} state={cur_state} "
                              f"-> {len(patch_ops)} ops "
                              f"ops={patch_ops[:5]}", flush=True)
                        if not patch_ops:
                            # Idempotent no-op: return 200 with the current resource body
                            # without bothering Ironic at all.
                            data = json.dumps(current).encode()
                            self.send_response(200)
                            self.send_header("Content-Type", "application/json")
                            self.send_header("Content-Length", str(len(data)))
                            self.end_headers()
                            self.wfile.write(data)
                            return
                    else:
                        print(f"[proxy] PATCH translator: GET failed ({g.status_code}); "
                              f"forwarding original body", flush=True)
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
