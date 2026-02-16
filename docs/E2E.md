# End-to-End Validation

## Prerequisites

- Kubernetes cluster with Ironic deployed (see `deploy/README.md`)
- oasgen-provider and rest-dynamic-controller installed
- Node CRD generated from RestDefinition

## Validation Steps

### 1. Validate Chart Templates

```bash
make validate-chart
```

Or manually:

```bash
make template-chart
```

Verify output contains:
- `apiVersion: baremetal.ogen.krateo.io/v1alpha1`
- `kind: Node`
- Node spec with driver, driver_info

### 2. Deploy Ironic Stack

```bash
./deploy/deploy-ironic-stack.sh
```

Or follow `deploy/README.md` step-by-step.

### 3. Apply RestDefinition

```bash
make apply-oas    # Creates OAS ConfigMap
make apply-restdef # Applies RestDefinition, deploys rest-dynamic-controller
```

Wait for rest-dynamic-controller to be ready. Check Node CRD:

```bash
kubectl get crd | grep baremetal
```

### 4. Deploy baremetal-lifecycle Chart

```bash
helm upgrade --install baremetal-lifecycle ./charts/baremetal-lifecycle \
  -n default \
  --set nodeName=my-baremetal-node \
  --set driver_info.ipmi_address=172.19.74.202 \
  --set driver_info.ipmi_username=admin \
  --set driver_info.ipmi_password=secret
```

### 5. Observe State Transitions

1. **Node CR created** – rest-dynamic-controller syncs to Ironic
2. **Job ironic-manage-*** – runs when `provision_state` is `enroll`
3. **Job ironic-provide-*** (or inspect first) – after manageable
4. **Job ironic-deploy-*** – when available (requires instance_info)

```bash
kubectl get nodes.baremetal.ogen.krateo.io -A
kubectl get jobs -A -l app.kubernetes.io/name=baremetal-lifecycle
kubectl logs job/ironic-manage-baremetal-lifecycle -f
```

### 6. Verify Node Status

```bash
kubectl get node <name> -o yaml
# Check status.provision_state, status.metadata.uuid
```

## Troubleshooting

See `README.md` Troubleshooting section.
