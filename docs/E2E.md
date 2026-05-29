# End-to-End Validation

Validated locally with `kind` + standalone Ironic (fake-hardware) — no real hardware.

## 1. Bring up the stack

```bash
make local-up
```

This creates the kind cluster `ironic-kog`, deploys standalone Ironic (official
openstack-helm image, fake drivers, noauth, + version-injecting nginx sidecar), installs
Krateo (`oasgen-provider` + `core-provider`), and applies the RestDefinition.

Check:

```bash
KCTL="kubectl --kubeconfig local/kubeconfig.ironic-kog --context kind-ironic-kog"
$KCTL -n krateo-system get pods                      # providers Running
$KCTL -n openstack get restdefinition ironic-node    # READY=True
$KCTL get crd | grep baremetal                       # nodes + nodeconfigurations CRDs
$KCTL -n openstack get deploy ironic-node-controller # rest-dynamic-controller Running
```

## 2. Provision a server via the composition

```bash
make provision-demo
```

This installs `charts/baremetal-lifecycle` for node `server01`. The chart renders:
- a `NodeConfiguration` (Ironic endpoint + microversion headers),
- a `Node` CR — KOG's rest-dynamic-controller creates the node in Ironic (`enroll`),
- a provisioner Job — drives `enroll → manage → provide → deploy → active`.

## 3. Observe

```bash
KCTL="kubectl --kubeconfig local/kubeconfig.ironic-kog --context kind-ironic-kog"
$KCTL -n openstack logs job/ironic-provision-baremetal-lifecycle   # "...server01 is active"
$KCTL -n openstack get node.baremetal.ogen.krateo.io server01      # Synced=True

# node state in Ironic:
$KCTL -n openstack exec deploy/ironic -c ironic -- \
  curl -s -H "X-OpenStack-Ironic-API-Version: 1.81" http://127.0.0.1:6385/v1/nodes \
  | jq -r '.nodes[] | .name+"  "+.provision_state'
# -> server01  active
```

The provisioner Job is idempotent and forward-only: re-running it on an already-`active`
node is a no-op (it never undeploys).

## API-only smoke test (no Krateo)

```bash
make smoke-test   # drives a fake node enroll->active directly via the Ironic API
```

## Troubleshooting

See the Troubleshooting section in the top-level `README.md`.
