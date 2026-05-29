# OpenStack Ironic + Krateo (KOG)

Provision bare metal servers with OpenStack Ironic using Krateo's dynamic controllers
instead of a hand-written operator.

- **KOG (Krateo Operator Generator)** — `oasgen-provider` + a `RestDefinition` generate a
  `Node` CRD and a `rest-dynamic-controller` that does Node CRUD against the Ironic API.
- **Composition** — `core-provider` + a `CompositionDefinition` run the
  `charts/baremetal-lifecycle` Helm chart. The chart renders the `Node` CR plus a single,
  idempotent **provisioner Job** that drives the standalone Ironic provision state machine
  (`enroll → manage → [inspect] → provide → deploy`) and stops at `active`. The composition
  *is* the orchestrator — there is no separate middleware service.

## Free local test environment

Everything runs locally on a laptop for free — no hardware, PXE, VMs, or public cloud.
An isolated `kind` cluster runs Krateo and a standalone Ironic (the official openstack-helm
image `quay.io/airshipit/ironic` with the `fake-hardware` driver, SQLite, noauth). See
[`local/README.md`](local/README.md).

```bash
make local-up        # kind + standalone Ironic + Krateo (KOG + core) + RestDefinition
make provision-demo  # composition provisions a sample fake node 'server01' -> active
make local-down      # tear down
```

All `kubectl`/`helm` use an isolated kubeconfig (`local/kubeconfig.ironic-kog`) and explicit
`--context kind-ironic-kog`, so your default `~/.kube/config` is never touched.

> The standalone Ironic pod includes an nginx sidecar that injects a default
> `X-OpenStack-Ironic-API-Version` header — Ironic rejects write requests without a
> microversion (HTTP 406), and the rest-dynamic-controller doesn't send one.

## Project layout

| Path | Description |
|------|-------------|
| `oas/ironic-node.yaml` | OpenAPI spec for Node CRUD (KOG input) |
| `manifests/restdefinition-node.yaml` | RestDefinition consumed by oasgen-provider |
| `manifests/compositiondefinition-baremetal-lifecycle.yaml` | CompositionDefinition for core-provider |
| `charts/baremetal-lifecycle/` | Helm chart: Node CR + NodeConfiguration + provisioner Job |
| `local/` | Free local env (kind config, standalone Ironic, kubeconfig isolation) |
| `deploy/` | openstack-helm Ironic deployment (full stack, for real clusters) |
| `scripts/` | OAS ConfigMap creation, Ironic smoke test |

## Makefile targets

Local env: `local-up`, `krateo-up`, `restdef-up`, `ironic-up`, `provision-demo`,
`ironic-forward`, `smoke-test`, `local-down` (run `make help`).

Chart/packaging: `package-chart`, `template-chart`, `validate-chart`.

## Using the Krateo composition (CompositionDefinition)

`make provision-demo` deploys the chart directly (what composition-dynamic-controller does
under the hood). To drive it through a `CompositionDefinition`:

1. `make package-chart` → `dist/baremetal-lifecycle-0.1.0.tgz`
2. Publish the `.tgz` (HTTP URL or `oci://…`) and set `spec.chart.url` in
   `manifests/compositiondefinition-baremetal-lifecycle.yaml`
3. `kubectl apply -f manifests/compositiondefinition-baremetal-lifecycle.yaml`, then create a
   Composition CR with your node values.

## Troubleshooting

**Provisioner Job stuck waiting for the node** — the Node CR must sync to Ironic first.
Check the controller: `kubectl -n openstack logs deploy/ironic-node-controller`. The Node CR
should be `Synced=True`.

**Node CR `create failed: 406`** — Ironic needs the microversion header; ensure the nginx
sidecar is running (`kubectl -n openstack get pod -l app=ironic` shows 2/2) or that the
NodeConfiguration sets `X-OpenStack-Ironic-API-Version`.

**Node CR `observe failed: 400`** — the path identifier must map to `spec.name`
(Ironic resolves `/v1/nodes/{name}`); see `manifests/restdefinition-node.yaml`.

**RestDefinition not Ready / CRD not regenerating** — config changes need a fresh generation:
`kubectl delete -f manifests/restdefinition-node.yaml`, restart `krateo-oasgen-provider`,
delete the stale `nodes`/`nodeconfigurations` CRDs, then re-apply.
