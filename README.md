# OpenStack Ironic + Krateo Dynamic Controllers

Integrates OpenStack Ironic with [rest-dynamic-controller](https://github.com/krateoplatformops/rest-dynamic-controller) and [composition-dynamic-controller](https://github.com/krateoplatformops/composition-dynamic-controller) to provision bare metal servers without custom operators.

## Architecture

- **rest-dynamic-controller**: Node CRUD (POST/GET/PATCH/DELETE) → Ironic API
- **composition-dynamic-controller**: Helm chart orchestration with Jobs for state transitions
- **Jobs**: Run `openstack baremetal node manage|inspect|provide|deploy|undeploy`

## Quick Start

1. Deploy Ironic (openstack-helm) → `deploy/README.md`
2. Apply RestDefinition → `make apply-restdef`
3. Deploy chart → `make deploy-chart` with values for your node

## Project Layout

| Path | Description |
|------|-------------|
| `oas/ironic-node.yaml` | OpenAPI spec for Node CRUD |
| `manifests/restdefinition-node.yaml` | RestDefinition for oasgen-provider |
| `manifests/compositiondefinition-baremetal-lifecycle.yaml` | CompositionDefinition for core-provider |
| `charts/baremetal-lifecycle/` | Helm chart (Node CR + Jobs) |
| `deploy/` | Ironic deployment values and docs |
| `scripts/` | OAS ConfigMap creation |

## Makefile Targets

- `apply-oas` – Create OAS ConfigMap
- `apply-restdef` – Apply RestDefinition
- `deploy-chart` – Helm install baremetal-lifecycle
- `deploy-ironic` – Helm install Ironic (openstack-helm)
- `package-chart` – Package chart for publishing
- `template-chart` – Dry-run chart templates
- `validate-chart` – Validate chart templates render

## Chart Publishing

To use the chart with core-provider (CompositionDefinition):

1. Package: `make package-chart` (outputs to `dist/`)
2. Publish the `.tgz` to an HTTP URL, OCI registry (e.g. `oci://ghcr.io/org/baremetal-lifecycle`), or Helm repo
3. Update `manifests/compositiondefinition-baremetal-lifecycle.yaml` `spec.chart.url` to the published URL
4. Apply: `kubectl apply -f manifests/compositiondefinition-baremetal-lifecycle.yaml`

On release, GitHub Actions packages the chart and uploads it as an artifact.

## Troubleshooting

**Job fails (manage, inspect, provide, deploy)**
- `kubectl logs job/ironic-<action>-baremetal-lifecycle` – check openstack client output
- Verify `ironicApiUrl` and `ironicAuthType` in chart values
- For BMC errors: confirm `driver_info` (ipmi_address, credentials) are correct

**Node CR not syncing to Ironic**
- Ensure rest-dynamic-controller is running: `kubectl get pods -A | grep rest-dynamic`
- Check RestDefinition is Ready: `kubectl get restdefinition -n openstack`
- Verify OAS ConfigMap exists: `kubectl get configmap ironic-node-oas -n openstack`

**Helm upgrade fails (Job already exists)**
- Jobs are one-shot; delete the completed Job or use `helm.sh/hook` (see plan)
