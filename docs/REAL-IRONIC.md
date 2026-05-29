# Quickstart: run the operator against a real Ironic API

The operator is the same as in the local (fake) env — only the endpoint behind the in-cluster
`ironic` Service changes. For a real, Keystone-protected Ironic (e.g. an OpenMetal hosted-private
cloud where you hold the admin role), a small **auth proxy** authenticates with your
`clouds.yaml`, injects a fresh `X-Auth-Token` + microversion, and forwards to the cloud's Ironic.
The operator's config (OAS endpoint, RestDefinitions, chart) is unchanged.

> Status: this path is wired and the proxy is unit-tested, but it has **not** yet been run end
> to end against a live cloud (no public free Ironic API exists — see the repo discussion). Treat
> it as the intended recipe; expect to iterate on cloud-specific quirks.

## Prerequisites

- A real OpenStack with the **`baremetal` (Ironic) service in the Keystone catalog** and
  admin/operator access (hosted-private such as OpenMetal; OpenMetal also has free trials).
- A `clouds.yaml` for it (Horizon → API Access, or the provider portal). Note the cloud name
  (top-level key under `clouds:`).
- Docker + kind + helm + kubectl (the operator runs in a local kind cluster).

## Steps

### 1. Bring up the operator (kind + Krateo + RestDefinitions)

```bash
make local-up
```

This installs Krateo (KOG `oasgen-provider` + composition `core-provider`) and applies both
RestDefinitions (`Node` CRUD + `NodeProvision` action). It also starts the local fake Ironic —
that's fine; the next step repoints the `ironic` Service away from it.

### 2. Point the operator at your real Ironic (Keystone auth proxy)

Put your file at `./clouds.yaml` (gitignored), then:

```bash
make openmetal-proxy-up CLOUDS_FILE=clouds.yaml OS_CLOUD=<your-cloud-name>
```

This creates a Secret from `clouds.yaml`, deploys the proxy (`scripts/openmetal-ironic-proxy.py`
in the openstack-client image, which uses `openstacksdk` to auto-refresh the Keystone token and
discover the `baremetal` endpoint), and repoints the `ironic` Service at it. The proxy listens on
the same port the operator already targets, so nothing else changes. `make openmetal-down` switches
back to the local fake Ironic.

### 3. Verify connectivity through the proxy

```bash
KCTL="kubectl --kubeconfig local/kubeconfig.ironic-kog --context kind-ironic-kog"
$KCTL -n openstack port-forward svc/ironic 6385:6385 &
curl -s -H "X-OpenStack-Ironic-API-Version: 1.81" http://localhost:6385/v1/nodes | jq .
```

A `200` with your real nodes (or an empty list) confirms Keystone auth + Ironic reachability.

### 4. Provision (real hardware values)

The fake driver from the local env won't drive real hardware. Edit
`manifests/baremetallifecycle-example.yaml` (or your composition instance) for your node:

```yaml
spec:
  nodeName: server01
  driver: redfish                 # or ipmi  (must be enabled on the cloud)
  driver_info:                    # real BMC details
    redfish_address: https://<bmc-ip>
    redfish_username: <user>
    redfish_password: <pass>
    redfish_verify_ca: false
  ports:                          # PXE NIC MAC(s)
    - address: "aa:bb:cc:dd:ee:ff"
  instance_info:                  # OS image to deploy
    image_source: http://<http-or-glance>/image.qcow2
    image_checksum: <sha256-or-url>
```

Then drive it through composition-dynamic-controller:

```bash
make composition-up      # host the chart + install the CompositionDefinition
make composition-demo    # create the BaremetalLifecycle instance
# watch it walk enroll -> manage -> manageable -> provide -> available -> deploy -> active:
$KCTL -n openstack get node.baremetal.ogen.krateo.io server01 -o jsonpath='{.status.provision_state}'
```

The composition renders one `NodeProvision` CR per state (selected by `lookup` of the node's
current `provision_state`); cdc re-evaluates each reconcile until the node is `active`.

## Self-hosted noauth Ironic (Bifrost) — variant

If your Ironic is standalone/noauth (e.g. Bifrost), you don't need the proxy. Instead route the
`ironic` Service at the external endpoint (a headless Service + manual EndpointSlice, or an
`ExternalName` Service) and ensure a microversion header is supplied (the local env's nginx
sidecar does this; reuse that pattern pointing at the external host). The operator stays unchanged.

## Notes / gotchas

- The microversion header is mandatory for Ironic writes; the proxy injects `1.81` (override with
  `IRONIC_API_VERSION`).
- The `Node` RestDefinition has **no `update` verb** on purpose (Ironic PATCH is JSON-Patch-only
  and clears `instance_info` during cleaning, which would freeze the Node CR). Node spec is set at
  create; lifecycle is via `NodeProvision`.
- Progression is paced by KOG's Node-controller status resync (tens of seconds per state) plus the
  real deploy time (minutes).
- App credentials: if your cloud supports Keystone application credentials, a `clouds.yaml` with
  `auth_type: v3applicationcredential` works with the proxy and is safer than your password.
