#!/bin/bash
# Create/refresh ConfigMaps holding the Ironic OpenAPI specs for oasgen-provider:
#   ironic-node-oas      <- oas/ironic-node.yaml
#   ironic-port-oas      <- oas/ironic-port.yaml
#   ironic-provision-oas <- oas/ironic-provision.yaml
#
# Run from repo root. Requires the target namespace to exist.
# Override KUBECTL to target a specific cluster, e.g.
#   KUBECTL="kubectl --kubeconfig local/kubeconfig.ironic-lab --context kind-ironic-lab"
# Configmap keys avoid '-' (KOG's oasPath regex disallows hyphens in the filename segment).
set -e
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${1:-openstack}"
KUBECTL="${KUBECTL:-kubectl}"

apply_oas_cm() {
  local cm_name="$1" key="$2" path="$3"
  $KUBECTL create configmap "$cm_name" \
    -n "$NAMESPACE" \
    --from-file="${key}=${path}" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  echo "ConfigMap $cm_name applied in namespace $NAMESPACE (from $path)"
}

apply_oas_cm ironic-node-oas      ironic_node.yaml "$REPO_ROOT/oas/ironic-node.yaml"
apply_oas_cm ironic-port-oas      ironic_port.yaml "$REPO_ROOT/oas/ironic-port.yaml"
apply_oas_cm ironic-provision-oas provision.yaml   "$REPO_ROOT/oas/ironic-provision.yaml"
apply_oas_cm ironic-power-oas     power.yaml       "$REPO_ROOT/oas/ironic-power.yaml"
