# kagent Agent: `ironic-kog-expert`

A [kagent](https://kagent.dev) Agent CRD that turns an LLM into a
subject-matter expert on this blueprint:

- The two-layer architecture (KOG-generated Ironic primitives + the
  `BaremetalHost` Helm chart reconciled as an FSM by Krateo core-provider).
- State-machine semantics, stuck-state recovery via `spec.undeploy`,
  `undeployMode=none` fast path.
- Comparison against `metal3-io/baremetal-operator` (see
  [`docs/VS-METAL3.md`](../docs/VS-METAL3.md)).

The system prompt embeds the non-obvious gotchas (port ordering, CRD
version stripping, stuck CRD finalizer, `system_scope:all` workaround,
no-manual-power-ops) and the triage recipe.

## Prerequisites

### 1. Install kagent

Pulled directly from the GHCR OCI registry — no `helm repo add` needed.
Verified working on kagent v0.9.6.

```bash
KCFG=local/kubeconfig.ironic-lab            # your isolated kubeconfig
KCTX=kind-ironic-lab                        # your cluster context

kubectl --kubeconfig "$KCFG" --context "$KCTX" \
  create ns kagent --dry-run=client -o yaml | \
  kubectl --kubeconfig "$KCFG" --context "$KCTX" apply -f -

helm --kubeconfig "$KCFG" --kube-context "$KCTX" \
  upgrade --install kagent-crds \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --version 0.9.6 --namespace kagent --wait --timeout 5m

helm --kubeconfig "$KCFG" --kube-context "$KCTX" \
  upgrade --install kagent \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --version 0.9.6 --namespace kagent \
  --set providers.default=anthropic \
  --set providers.anthropic.model=claude-sonnet-4-6 \
  --timeout 10m
```

Swap `providers.default` for `openAI`, `gemini`, `azureOpenAI`, or
`ollama` if you don't want Anthropic. The helm chart auto-creates a
`ModelConfig` named `default-model-config` matching whichever provider
you picked — the Agent CRD here references that name.

### 2. Populate the `ModelConfig`'s API key secret

The auto-created `default-model-config` points at a secret the chart
doesn't create for you (it can't — you own the key). For Anthropic the
secret name is `kagent-anthropic` and the key is `ANTHROPIC_API_KEY`:

```bash
kubectl --kubeconfig "$KCFG" --context "$KCTX" \
  create secret generic kagent-anthropic \
  -n kagent \
  --from-literal=ANTHROPIC_API_KEY='sk-ant-...your-key...'
```

Other providers map to different secret names — the chart prints them
during install. Quick reference:

| `providers.default` | secret name        | secret key            |
|---------------------|--------------------|-----------------------|
| `anthropic`         | `kagent-anthropic` | `ANTHROPIC_API_KEY`   |
| `openAI`            | `kagent-openai`    | `OPENAI_API_KEY`      |
| `gemini`            | `kagent-gemini`    | `GOOGLE_API_KEY`      |
| `azureOpenAI`       | `kagent-azure-openai` | `AZUREOPENAI_API_KEY` |

### 3. Built-in `kagent-tool-server`

Shipped automatically by the kagent helm chart as a `RemoteMCPServer`.
Provides the `k8s_*` tool family the Agent uses. No extra setup.

## Apply

```bash
kubectl --kubeconfig "$KCFG" --context "$KCTX" \
  apply -f kagent/agent-ironic-expert.yaml
kubectl --kubeconfig "$KCFG" --context "$KCTX" \
  -n kagent get agent ironic-kog-expert
```

Then open the kagent UI (or the A2A endpoint) and ask one of the example
prompts under `spec.declarative.a2aConfig.skills`:

- "How does the `BaremetalHost` composition drive Ironic state transitions?"
- "`blade07` has been in `wait call-back` for 20 minutes — what now?"
- "Why would I pick this over metal3?"
- "Walk me through the `spec.undeploy` widening introduced in v0.3.4."

## What the agent can do

- Read `BaremetalHost`, `Node`, `Port`, `NodeProvision`, `NodePower` CRs
  and explain the live FSM position.
- Patch `spec.undeploy`, `spec.online`, `spec.image` on a `BaremetalHost`
  to drive the FSM (with confirmation).
- Tail pod logs from `keystone-ironic-proxy` and the cdc when diagnosing
  reconciliation hangs.
- Cite the canonical docs (`USER-GUIDE.md`, `VS-METAL3.md`,
  `TEST-PLAN.md`, `ORPHAN-RECOVERY.md`) verbatim where relevant.

## What the agent will not do

- Curl Ironic power endpoints directly (always goes through `spec.online`).
- Recommend `kubectl delete bh <name>` on an `active` blade — it walks
  you through `spec.undeploy: true` first.
- Mock or invent Ironic state — it reads `provision_state` from the live
  `Node` CR via `k8s_get_resource_yaml`.
