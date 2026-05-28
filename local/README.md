# Free local test environment

A self-contained, no-cost Ironic environment for developing and testing the operator
on a laptop — no physical hardware, no PXE, no VMs, no public cloud.

## What it is

- A **kind** cluster (`ironic-kog`) where Krateo (KOG + composition) and the operator run.
- **Standalone Ironic** in namespace `openstack`, reachable in-cluster at
  `http://ironic.openstack.svc.cluster.local:6385`.
  - Image: `quay.io/airshipit/ironic:2026.1-ubuntu_noble` — the **official openstack-helm
    image** (built by OpenStack-Helm/Airship via LOCI), running the combined `ironic`
    binary (API + conductor in one process).
  - Config (`ironic.conf`): `auth_strategy=noauth`, SQLite, `rpc_transport=json-rpc`,
    `fake-hardware` drivers (all interfaces `fake`/`no-*`/`noop`), `automated_clean=false`.
    No MariaDB / RabbitMQ / Keystone.

With the fake drivers the full provision state machine runs without any real hardware:
`enroll → manage → manageable → inspect → manageable → provide → available → (set
instance_info) → active`.

> Note: the image is amd64-only; on Apple Silicon it runs under Docker Desktop's shared
> qemu emulation inside the kind node (validated working).

## kubeconfig isolation

The cluster lives in an **isolated kubeconfig** (`local/kubeconfig.ironic-kog`, gitignored).
Every `kubectl`/`helm` call uses `--kubeconfig local/kubeconfig.ironic-kog --context
kind-ironic-kog`, so your default `~/.kube/config` is never modified.

## Usage

```bash
make local-up        # create kind cluster + deploy standalone Ironic
make smoke-test      # drive a fake node enroll -> active (CLEANUP=1 deletes it after)
make ironic-forward  # expose the API at http://localhost:6385 (separate shell)
make local-down      # delete the kind cluster
```

Manual API access (after `make ironic-forward`):

```bash
curl -s -H "X-OpenStack-Ironic-API-Version: 1.81" http://localhost:6385/v1/nodes | jq
```

## Files

| File | Purpose |
|------|---------|
| `ironic.conf` | Standalone Ironic config (noauth, sqlite, fake drivers) |
| `ironic-standalone.yaml` | Namespace + Deployment + Service for in-cluster Ironic |
| `kubeconfig.ironic-kog` | Isolated kubeconfig (generated, gitignored) |
