#!/bin/bash
# Create ConfigMap with Ironic Node OpenAPI spec for oasgen-provider.
# Run from repo root. Requires namespace openstack to exist.
set -e
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${1:-openstack}"
kubectl create configmap ironic-node-oas \
  -n "$NAMESPACE" \
  --from-file=ironic-node.yaml="$REPO_ROOT/oas/ironic-node.yaml" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "ConfigMap ironic-node-oas created/updated in namespace $NAMESPACE"
