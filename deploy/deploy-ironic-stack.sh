#!/bin/bash
# Deploy OpenStack-Helm stack for Ironic (minimal: backends + keystone + glance + neutron + ironic)
# Prerequisites: K8s cluster, helm 3+, openstack-helm plugin, openstack namespace, Ceph/object store
# Run from project root: ./deploy/deploy-ironic-stack.sh
#
# Optional: OVERRIDES_URL, SKIP_GLANCE_PVC, IRONIC_ONLY (skip backends if already deployed)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="${NAMESPACE:-openstack}"

export OPENSTACK_RELEASE="${OPENSTACK_RELEASE:-2025.1}"
export FEATURES="${OPENSTACK_RELEASE} ubuntu_noble"
export OVERRIDES_DIR="${OVERRIDES_DIR:-$REPO_ROOT/deploy/overrides}"
export OVERRIDES_URL="${OVERRIDES_URL:-https://opendev.org/openstack/openstack-helm/raw/branch/master/values_overrides}"

echo "Deploying to namespace: $NAMESPACE"
echo "Overrides dir: $OVERRIDES_DIR"

mkdir -p "$OVERRIDES_DIR"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if [[ "${IRONIC_ONLY:-}" != "true" ]]; then
  echo "=== Downloading values overrides ==="
  for chart in rabbitmq mariadb memcached keystone glance neutron; do
    helm osh get-values-overrides -d -u "${OVERRIDES_URL}" -p "${OVERRIDES_DIR}" -c "$chart" ${FEATURES} 2>/dev/null || true
  done

  echo "=== Deploying RabbitMQ ==="
  helm upgrade --install rabbitmq openstack-helm/rabbitmq \
    --namespace="$NAMESPACE" \
    --set pod.replicas.server=1 \
    --timeout=600s \
    $(helm osh get-values-overrides -p "${OVERRIDES_DIR}" -c rabbitmq ${FEATURES} 2>/dev/null || echo "")
  helm osh wait-for-pods "$NAMESPACE" 2>/dev/null || sleep 30

  echo "=== Deploying MariaDB ==="
  helm upgrade --install mariadb openstack-helm/mariadb \
    --namespace="$NAMESPACE" \
    --set pod.replicas.server=1 \
    $(helm osh get-values-overrides -p "${OVERRIDES_DIR}" -c mariadb ${FEATURES} 2>/dev/null || echo "")
  helm osh wait-for-pods "$NAMESPACE" 2>/dev/null || sleep 30

  echo "=== Deploying Memcached ==="
  helm upgrade --install memcached openstack-helm/memcached \
    --namespace="$NAMESPACE" \
    $(helm osh get-values-overrides -p "${OVERRIDES_DIR}" -c memcached ${FEATURES} 2>/dev/null || echo "")
  helm osh wait-for-pods "$NAMESPACE" 2>/dev/null || sleep 20

  echo "=== Deploying Keystone ==="
  helm upgrade --install keystone openstack-helm/keystone \
    --namespace="$NAMESPACE" \
    $(helm osh get-values-overrides -p "${OVERRIDES_DIR}" -c keystone ${FEATURES} 2>/dev/null || echo "")
  helm osh wait-for-pods "$NAMESPACE" 2>/dev/null || sleep 60

  echo "=== Deploying Glance ==="
  GLANCE_ARGS=$(helm osh get-values-overrides -p "${OVERRIDES_DIR}" -c glance ${FEATURES} 2>/dev/null || echo "")
  if [[ "${SKIP_GLANCE_PVC:-}" != "true" ]]; then
    mkdir -p "${OVERRIDES_DIR}/glance"
    if [[ ! -f "${OVERRIDES_DIR}/glance/glance_pvc_storage.yaml" ]]; then
      echo "Creating glance PVC override - ensure storage class exists"
      tee "${OVERRIDES_DIR}/glance/glance_pvc_storage.yaml" << 'GLANCE_EOF' || true
conf:
  glance:
    DEFAULT:
      enabled_backends: default:file
    glance_store:
      default_backend: default
      stores: default.file.Store
      default_store: file
manifests:
  job_db_init: false
  job_db_drop: false
GLANCE_EOF
    fi
    GLANCE_ARGS="$GLANCE_ARGS -f ${OVERRIDES_DIR}/glance/glance_pvc_storage.yaml"
  fi
  helm upgrade --install glance openstack-helm/glance \
    --namespace="$NAMESPACE" \
    $GLANCE_ARGS
  helm osh wait-for-pods "$NAMESPACE" 2>/dev/null || sleep 60

  echo "=== Deploying Neutron (minimal) ==="
  helm upgrade --install neutron openstack-helm/neutron \
    --namespace="$NAMESPACE" \
    $(helm osh get-values-overrides -p "${OVERRIDES_DIR}" -c neutron ${FEATURES} 2>/dev/null || echo "")
  helm osh wait-for-pods "$NAMESPACE" 2>/dev/null || sleep 60
fi

echo "=== Deploying Ironic ==="
helm upgrade --install ironic openstack-helm/ironic \
  --namespace="$NAMESPACE" \
  -f "$SCRIPT_DIR/values/ironic-overrides.yaml"

echo "Done. Wait for ironic pods: kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=ironic"
