#!/bin/bash
# Create ConfigMap with Ironic Node OpenAPI spec for oasgen-provider.
# Run from repo root. Requires namespace openstack to exist.
set -e
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${1:-openstack}"
# Override KUBECTL to target a specific cluster, e.g.
#   KUBECTL="kubectl --kubeconfig local/kubeconfig.ironic-kog --context kind-ironic-kog"
KUBECTL="${KUBECTL:-kubectl}"
# Key must avoid '-' (KOG oasPath regex disallows hyphens in the filename segment).
$KUBECTL create configmap ironic-node-oas \
  -n "$NAMESPACE" \
  --from-file=ironic_node.yaml="$REPO_ROOT/oas/ironic-node.yaml" \
  --dry-run=client -o yaml | $KUBECTL apply -f -
echo "ConfigMap ironic-node-oas created/updated in namespace $NAMESPACE"
