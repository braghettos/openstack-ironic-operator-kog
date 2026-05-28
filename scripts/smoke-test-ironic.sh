#!/usr/bin/env bash
# Smoke-test the standalone Ironic API by driving a fake node through the full
# provision state machine (the same flow the composition implements):
#   enroll -> manage -> (inspect) -> provide -> set instance_info -> active
#
# Requires: curl, jq. Targets a noauth Ironic at $IRONIC_API (default localhost:6385).
# Use `make ironic-forward` (or kubectl port-forward svc/ironic 6385:6385) first.
#
#   IRONIC_API=http://localhost:6385 NODE=test-server01 RUN_INSPECT=1 CLEANUP=1 \
#     ./scripts/smoke-test-ironic.sh
set -euo pipefail

API="${IRONIC_API:-http://localhost:6385}"
NODE="${NODE:-test-server01}"
MAC="${MAC:-9c:b6:54:b2:b0:ca}"
RUN_INSPECT="${RUN_INSPECT:-1}"
CLEANUP="${CLEANUP:-0}"
H="X-OpenStack-Ironic-API-Version: 1.81"
CT="Content-Type: application/json"

api() { curl -fsS -H "$H" "$@"; }

wait_state() { # $1=target provision_state
  local want="$1" got="" i
  for i in $(seq 1 60); do
    got=$(api "$API/v1/nodes/$NODE" | jq -r .provision_state)
    if [ "$got" = "$want" ]; then echo "  -> $want"; return 0; fi
    case "$got" in *failed*) echo "  !! node in $got"; api "$API/v1/nodes/$NODE" | jq -r .last_error; return 1;; esac
    sleep 1
  done
  echo "  !! timeout waiting for '$want' (last='$got')"; return 1
}

provision() { api -H "$CT" -X PUT "$API/v1/nodes/$NODE/states/provision" -d "{\"target\":\"$1\"}"; }

echo "Ironic API: $API   node: $NODE"
echo "== create node (enroll) =="
UUID=$(api -H "$CT" -X POST "$API/v1/nodes" \
  -d "{\"name\":\"$NODE\",\"driver\":\"fake-hardware\"}" | jq -r .uuid)
echo "  uuid=$UUID"

echo "== add port =="
# /v1/ports requires the node's real UUID in node_uuid (the node name is rejected with 400)
api -H "$CT" -X POST "$API/v1/ports" \
  -d "{\"node_uuid\":\"$UUID\",\"address\":\"$MAC\",\"pxe_enabled\":true}" >/dev/null && echo "  port $MAC added"

echo "== manage =="; provision manage >/dev/null; wait_state manageable
if [ "$RUN_INSPECT" = "1" ]; then
  echo "== inspect =="; provision inspect >/dev/null; wait_state manageable
fi
echo "== provide =="; provision provide >/dev/null; wait_state available

echo "== set instance_info (image) =="
api -H "$CT" -X PATCH "$API/v1/nodes/$NODE" -d '[
  {"op":"add","path":"/instance_info/image_source","value":"http://example.invalid/image.qcow2"},
  {"op":"add","path":"/instance_info/image_checksum","value":"00000000000000000000000000000000"}
]' >/dev/null && echo "  instance_info set"

echo "== deploy (active) =="; provision active >/dev/null; wait_state active

echo "== RESULT =="
api "$API/v1/nodes/$NODE" | jq '{name,provision_state,power_state,target_provision_state}'

if [ "$CLEANUP" = "1" ]; then
  echo "== cleanup: undeploy + delete =="
  provision deleted >/dev/null; wait_state available
  api -X DELETE "$API/v1/nodes/$NODE" >/dev/null && echo "  node deleted"
fi
echo "OK: standalone Ironic drove a fake node to 'active'."
