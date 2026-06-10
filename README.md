<p align="center">
  <img src="docs/krateo-loves-ironic.png" alt="Krateo loves OpenStack Ironic" width="900"/>
</p>

> 📖 **[Quickstart](docs/quickstart.md)** — install the operator and see a resource appear in Horizon.


# OpenStack Ironic + Krateo (KOG)

Provision bare metal servers with OpenStack Ironic using Krateo's dynamic controllers
instead of a hand-written operator.

- **KOG (Krateo Operator Generator)** — `oasgen-provider` + RestDefinitions generate CRDs and
  `rest-dynamic-controller`s that talk to the Ironic API. Two RestDefinitions, each adherent to
  the Ironic API:
  - **`Node`** → CRUD on `/v1/nodes` (`manifests/restdefinition-node.yaml`).
  - **`NodeProvision`** → the provision action `PUT /v1/nodes/{id}/states/provision`
    (`manifests/restdefinition-provision.yaml`). Creating a `NodeProvision` fires the PUT once
    (a `202` sets a Pending condition that prevents re-firing).
- **Composition** — `core-provider` + a `CompositionDefinition` run the
  `charts/baremetal-lifecycle` Helm chart. The state machine is modeled as **one custom
  resource per state**: the chart renders the `Node` CR plus a single `NodeProvision` CR for the
  node's *current* `provision_state`, selected by the Helm `lookup` function. **composition-dynamic-controller
  re-evaluates `lookup` on every reconcile**, rendering the next transition and pruning the
  previous one, walking `enroll → manage → manageable → provide → available → deploy → active`.
  The composition *is* the orchestrator (no CLI, no middleware service); all transitions go
  through the Ironic API via KOG.

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
| `oas/ironic-provision.yaml` | OpenAPI spec for the provision action (KOG input) |
| `oas/ironic-port.yaml` | OpenAPI spec for Port CRUD (NIC on a node) |
| `oas/ironic-portgroup.yaml` | OpenAPI spec for Portgroup CRUD (bonded NICs) |
| `oas/ironic-allocation.yaml` | OpenAPI spec for Allocation CRUD (node matching/binding) |
| `oas/ironic-deploy-template.yaml` | OpenAPI spec for Deploy Template CRUD (trait -> deploy steps) |
| `manifests/restdefinition-node.yaml` | RestDefinition: Node CRUD |
| `manifests/restdefinition-provision.yaml` | RestDefinition: NodeProvision action |
| `manifests/restdefinition-port.yaml` | RestDefinition: Port (`Port`) |
| `manifests/restdefinition-portgroup.yaml` | RestDefinition: Portgroup (`PortGroup`) |
| `manifests/restdefinition-allocation.yaml` | RestDefinition: Allocation (`Allocation`) |
| `manifests/restdefinition-deploy-template.yaml` | RestDefinition: Deploy Template (`DeployTemplate`) |
| `manifests/compositiondefinition-baremetal-lifecycle.yaml` | CompositionDefinition for core-provider |
| `manifests/baremetallifecycle-example.yaml` | Example composition instance |
| `charts/baremetal-lifecycle/` | Helm chart: Node + NodeConfiguration + per-state NodeProvision CRs |
| `local/` | Free local env (kind config, standalone Ironic, kubeconfig isolation) |
| `deploy/` | openstack-helm Ironic deployment (full stack, for real clusters) |
| `scripts/` | OAS ConfigMap creation, Ironic smoke test |

## Makefile targets

Local env: `local-up`, `krateo-up`, `restdef-up`, `ironic-up`, `provision-demo`,
`ironic-forward`, `smoke-test`, `local-down` (run `make help`).

Chart/packaging: `package-chart`, `template-chart`, `validate-chart`.

## Driving it with composition-dynamic-controller

This is the real flow (the state machine is lookup-driven, so it needs the controller's
repeated reconciles — a single `helm install` only advances one step):

```bash
make composition-up    # package + host the chart, apply the CompositionDefinition
make composition-demo  # create a BaremetalLifecycle instance; cdc walks it to active
# watch:
kubectl -n openstack get node.baremetal.ogen.krateo.io metal-a -o jsonpath='{.status.provision_state}'
```

`composition-up` serves the chart from an in-cluster nginx (`make chart-host`) and points the
CompositionDefinition at it; `core-provider` then generates a `BaremetalLifecycle` CRD +
controller. For a real cluster, publish the `.tgz` (`make package-chart`) to HTTP/OCI and set
`spec.chart.url` in `manifests/compositiondefinition-baremetal-lifecycle.yaml`.

> Pacing: progression is gated by KOG's Node-controller status resync (~tens of seconds per
> state), so a full enroll→active walk takes a few minutes against the fake driver.

`make provision-demo` is a lighter alternative that simulates reconciles with repeated
`helm upgrade` (no CompositionDefinition needed).

## Multi-version CompositionDefinitions: apply at the right `apiVersion`

The Krateo `core-provider` deliberately keeps every prior chart version served on the
generated CRD, so that multiple consumers can pin to different chart versions of the same
composition. After bumping the chart from `0.2.0` → `0.2.1` → `0.3.0`, the generated
`BaremetalLifecycle` CRD has all three (plus a `vacuum` storage version) marked
`served: true`. This is **intentional** — not a bug — and it's the same architecture used
for `BaremetalDiscovery` and `BaremetalHost`. Storage is `vacuum` with
`x-kubernetes-preserve-unknown-fields: true`, and a conversion webhook translates between
versions on read.

**The one rule that catches everyone**: when you `kubectl apply -f`, you must set
`apiVersion: composition.krateo.io/v0-X-Y` to a version whose schema actually has the
fields you're using. If you apply with an older `apiVersion`, the kube-apiserver
schema-prunes fields the older schema doesn't know about — silently, at write-time. The
file looks right, the apply succeeds, but the spec stored under `vacuum` is missing the
new fields, and `cdc` (which reads its own precise GVR) sees an incomplete spec.

```yaml
# Correct: applying a BaremetalHost that uses spec.online (introduced in v0-1-0)
# and spec.maintenance (introduced in v0-1-2) — apply at v0-1-2 or later.
apiVersion: composition.krateo.io/v0-1-2     # ← the version that has BOTH fields
kind: BaremetalHost
metadata:
  name: blade03
spec:
  nodeName: blade03
  online: true
  maintenance: false
  ...
```

If you apply the same body at `composition.krateo.io/v0-1-0`, `spec.maintenance` is
silently dropped (v0-1-0's schema doesn't have it), the chart renders without the
maintenance flag, and Ironic stays out of maintenance even though the file said `true`.
This will look like a chart bug; it is not.

**Reading defaults to the OLDEST served version** (a `kubectl` UX nuisance, not a runtime
issue). Plain `kubectl get baremetalhost blade03 -o yaml` returns the body translated to
the first version in `spec.versions[]`, which is usually the oldest. To see the latest
schema's view, hit the precise endpoint:

```bash
kubectl get --raw \
  /apis/composition.krateo.io/v0-1-2/namespaces/openstack/baremetalhosts/blade03 | jq .
```

`cdc-v0-1-2-controller` reads via its own GVR, so its view is always complete; only humans
using default `kubectl get` see the trimmed body.

**Symptoms to recognize:**
- `helm get values <release>` shows default values for fields you set on the CR spec
  → applied at the wrong `apiVersion`, the field was stripped at write-time.
- `Warning: unknown field "spec.X"` from `kubectl apply` or `kubectl patch`
  → the `apiVersion` you targeted doesn't have field X. Switch to a newer one.
- `kubectl get <CR> -o yaml` showing `apiVersion: composition.krateo.io/v0-X-Y` lower than
  what you applied → cosmetic, the stored data is fine; verify with `kubectl get --raw`.

**Fixing existing CRs that were applied at an old version**: re-apply with the correct
newer `apiVersion`. The `vacuum` storage preserves what you write, so the new fields will
stick this time. You don't need to delete the CR.

## Lifecycle: image edits and undeploy

Both are driven by the composition's normal upgrade-on-reconcile loop — no Helm hooks, no
Jobs, no extra RBAC. The chart's templates use Helm `lookup` to read live Ironic state and
render whatever transition CR matches the current desire-vs-observed delta.

| Operator action | Chart behavior | Ironic transition |
|---|---|---|
| `kubectl patch bh <name> --type=merge -p '{"spec":{"undeploy":true}}'` | `transition-undeploy.yaml` renders a `NodeProvision` with `target: deleted` | `active → deleted → cleaning → available` (or skip `cleaning` if `undeployMode: none`) |
| Image swap on a deployed blade | Undeploy first (`spec.undeploy: true`), wait for `available`, then change `spec.image.source` and clear `undeploy`. The chart's normal deploy path then runs with the new image. | `active → deleted → cleaning → available → deploy → active` |
| `kubectl delete baremetalhost <name>` | cdc runs `helm uninstall`: removes the Node + Port + NodeProvision CRs. **Does NOT trigger an Ironic state walk.** | If Ironic is at `available`, KOG's `DELETE /v1/nodes/{id}` succeeds and the blade is removed. If Ironic is at `active`, KOG gets a 409 and the BH CR disappears from k8s while Ironic keeps running the blade. **Always undeploy first.** |
| Remove `spec.image` from the BH CR | **No-op.** Field-level "park to available" is not supported. Use `undeploy: true` to release the blade. | — |

**Why no in-place rebuild?** Ironic supports `target: rebuild` for hot image swaps without
going through `cleaning`. We don't expose it from the chart because the canonical Ironic
rebuild requires `node.instance_info.image_source` to be PATCHed *before* the rebuild PUT
fires, and the translator deliberately blocks `instance_info` writes while `active` to
prevent "metadata flips silently without redeploy" drift. The undeploy → swap → deploy
path uses only primitives we already have and validated, avoids any new race window, and
keeps the chart's surface area minimal. Cleaning takes longer (~minutes), which is the
trade-off; for production blades you usually *want* the cleaning pass after a release.

### Why undeploy is a spec field, not a deletion side-effect

cdc's reconcile loop has two paths and they're asymmetric:

- **Install / upgrade** (BH spec changes): cdc calls `helm upgrade`, the chart re-renders
  against live `lookup` state, and the composition drives the state machine one transition
  at a time. This is how every other `transition-*.yaml` works.
- **Delete** (BH has `deletionTimestamp`): cdc calls `helm uninstall` directly. **No
  `helm upgrade` re-render.** (Source: `composition-dynamic-controller` v1.0.0
  `internal/composition/composition.go:697`.)

So `kubectl delete bh` cannot drive a state-machine walk through Ironic — the composition
isn't being asked to render anything new. Coupling undeploy to BH deletion would have
required a Helm pre-delete hook (a `Job` with custom RBAC) just to bridge that gap. By
making undeploy a spec field instead, we stay on the same upgrade-on-reconcile rail every
other transition uses.

### Standard undeploy workflow

```bash
# 1. release the blade back to `available`. Composition drives the state walk.
kubectl patch baremetalhost blade05 --type=merge -p='{"spec":{"undeploy":true}}'

# 2. (optional) wait until Ironic reaches `available`. The BH CR's status reflects this.
kubectl get baremetalhost blade05 -w   # provision_state will tick through deleted -> cleaning -> available

# 3. (optional) remove the blade from k8s entirely. Now safe — Ironic is at `available`,
#    so KOG's DELETE /v1/nodes/{id} round-trips cleanly with no orphan.
kubectl delete baremetalhost blade05

# Re-deploy instead of deleting: clear undeploy and (optionally) change the image.
kubectl patch baremetalhost blade05 --type=merge \
  -p='{"spec":{"undeploy":false,"image":{"source":"http://.../new.qcow2","checksum":"..."}}}'
```

### Cleanup modes

`spec.undeployMode` controls Ironic's cleanup pass between `deleted` and `available`. It's
applied via `spec.automated_clean` on the Node CR, set at install time (no race with the
`target: deleted` PUT — Ironic reads `automated_clean` when it transitions out of `deleted`).

| Mode | What Ironic does between `deleted` and `available` | When to use |
|---|---|---|
| `full` (default) | `automated_clean=true` (or whatever ironic.conf default is). IPA boots, runs the standard `clean_steps` (disk erase, RAID/BIOS reset, etc.) | Production. Tenant data must not leak. |
| `none` | `spec.automated_clean=false` on the Node CR. No IPA boot. Goes `deleted → available` in seconds. Disks keep tenant data. | Private labs, fast teardown for testing. **Not safe for shared hardware.** |

Custom `clean_steps` during the post-delete pass are not first-class in Ironic — for that,
use the existing `cleanSteps` field, which runs from `manageable` via `target: clean`.

## Against a real Ironic API

Two paths, neither needs operator changes:

- **Standalone Ironic on a Linux host (Bifrost)** — real PXE deploys to libvirt VMs as virtual
  bare metal, no Keystone/Glance/Nova. `make bifrost-up BIFROST_URL=http://<host>:6385`.
  Full quickstart: **[docs/BIFROST.md](docs/BIFROST.md)**.
- **Keystone-protected Ironic** (on-prem, hosted-private, any) — auth proxy authenticates with
  your `clouds.yaml`. `make keystone-up CLOUDS_FILE=clouds.yaml OS_CLOUD=<name>`. Full
  step-by-step: **[docs/REAL-IRONIC.md](docs/REAL-IRONIC.md)**.

## Troubleshooting

**State machine not progressing** — the transitions are gated by `lookup` of the Node CR's
`status.provision_state`. If the Node CR is in `Synced=ReconcileError`, status stops updating
and the walk stalls. Check `kubectl -n openstack get node.baremetal.ogen.krateo.io <name>
-o jsonpath='{.status.conditions}'`. (This is why the Node RestDefinition has no `update` verb —
Ironic PATCH is JSON-Patch-only and 400s.) Otherwise it's just slow (KOG status resync ~tens of
seconds per state).

**NodeProvision fires the PUT repeatedly** — it shouldn't; the `202` Pending condition guards
re-firing. Ensure the OAS provision response is `202` and there is no `get` verb on the
NodeProvision RestDefinition.

**Node CR `create failed: 406`** — Ironic needs the microversion header; ensure the nginx
sidecar is running (`kubectl -n openstack get pod -l app=ironic` shows 2/2) or that the
NodeConfiguration sets `X-OpenStack-Ironic-API-Version`.

**Node CR `observe failed: 400`** — the path identifier must map to `spec.name`
(Ironic resolves `/v1/nodes/{name}`); see `manifests/restdefinition-node.yaml`.

**RestDefinition not Ready / CRD not regenerating** — config changes need a fresh generation:
`kubectl delete -f manifests/restdefinition-node.yaml`, restart `krateo-oasgen-provider`,
delete the stale `nodes`/`nodeconfigurations` CRDs, then re-apply.

**`Warning: unknown field "spec.X"` on `kubectl apply` / `kubectl patch`** — the
`apiVersion` you targeted (or the cluster's default for that kind, when you didn't
specify one) doesn't have field X. Field is silently stripped at write-time. See
[Multi-version CompositionDefinitions](#multi-version-compositiondefinitions-apply-at-the-right-apiversion):
re-apply at a newer `apiVersion`, e.g. `composition.krateo.io/v0-1-2`.

**`helm get values <release>` shows default values for fields you set on the CR spec** —
same root cause as above: the CR was written at an `apiVersion` whose schema didn't have
those fields, so they were dropped before the spec was stored. Re-apply at the right
version; vacuum storage preserves the new fields.
