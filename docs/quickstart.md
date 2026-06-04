# Quickstart — Ironic (bare metal) operator

Manage OpenStack **Ironic** bare-metal resources as Kubernetes CRs. End to end:
install the operator, `kubectl apply` a `Node`, and the operator enrolls it in Ironic.

> **Horizon note:** Ironic has no panel in a stock Horizon (it needs the separate
> `ironic-ui` dashboard plugin), and enrolling a node requires a running
> `ironic-conductor` on a provisioning network — i.e. **real bare-metal infra**.
> This quickstart therefore verifies with the `openstack baremetal` CLI. For the
> full lifecycle (enroll → active) driven by a Krateo Composition, see
> [`docs/E2E.md`](E2E.md) and [`docs/REAL-IRONIC.md`](REAL-IRONIC.md).

## 1. Prerequisites

Krateo's KOG provider in the cluster:

```bash
helm repo add krateo https://charts.krateo.io && helm repo update
helm upgrade --install oasgen-provider krateo/oasgen-provider -n krateo-system --create-namespace
```

Ironic reachable in-cluster (`ironic-api` on `:6385`). Because Ironic is
Keystone-protected and needs a microversion header, point the operator at an
auth proxy (see `docs/REAL-IRONIC.md`) at a **distinct** Service (the openstack-helm
chart already owns the `ironic` Service name).

## 2. Install the operator

```bash
kubectl create configmap ironic-node-oas -n openstack \
  --from-file=ironic_node.yaml=oas/ironic-node.yaml
kubectl apply -f manifests/restdefinition-node.yaml
kubectl wait restdefinition/ironic-node -n openstack --for=condition=Ready --timeout=300s
kubectl get crd | grep nodes.baremetal.ogen.krateo.io
```

## 3. Enroll a node

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: baremetal.ogen.krateo.io/v1alpha1
kind: NodeConfiguration
metadata: {name: ironic-config, namespace: openstack}
spec:
  configuration:
    header:
      create: {X-Ironic-Endpoint: "http://ironic-kog-proxy.openstack.svc.cluster.local:6385", X-OpenStack-Ironic-API-Version: "1.81"}
      get:    {X-Ironic-Endpoint: "http://ironic-kog-proxy.openstack.svc.cluster.local:6385", X-OpenStack-Ironic-API-Version: "1.81"}
      delete: {X-Ironic-Endpoint: "http://ironic-kog-proxy.openstack.svc.cluster.local:6385", X-OpenStack-Ironic-API-Version: "1.81"}
      findby: {X-Ironic-Endpoint: "http://ironic-kog-proxy.openstack.svc.cluster.local:6385", X-OpenStack-Ironic-API-Version: "1.81"}
---
apiVersion: baremetal.ogen.krateo.io/v1alpha1
kind: Node
metadata: {name: metal-a, namespace: openstack}
spec:
  configurationRef: {name: ironic-config, namespace: openstack}
  name: metal-a
  driver: ipmi
  driver_info: {ipmi_address: "172.24.6.10", ipmi_username: admin, ipmi_password: secret}
  resource_class: baremetal
EOF
```

## 4. Verify

```bash
openstack baremetal node list
# +--------------------------------------+---------+---------------+-------------+--------------------+-------------+
# | UUID                                 | Name    | Instance UUID | Power State | Provisioning State | Maintenance |
# +--------------------------------------+---------+---------------+-------------+--------------------+-------------+
# | ...                                  | metal-a | None          | None        | enroll             | False       |
# +--------------------------------------+---------+---------------+-------------+--------------------+-------------+
```

Drive `enroll → manageable → available → active` with `NodeProvision` CRs (or a
`BaremetalLifecycle` Composition). `Port`, `PortGroup`, `Allocation` and
`DeployTemplate` are managed the same way.
