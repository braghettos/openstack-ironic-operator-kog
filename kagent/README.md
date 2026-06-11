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

1. kagent installed in the cluster (see
   [kagent.dev/docs](https://kagent.dev)).
2. A kagent `ModelConfig` named `kagent-default` in the `kagent` namespace,
   or edit `spec.declarative.modelConfig` in
   [`agent-ironic-expert.yaml`](./agent-ironic-expert.yaml) to point at
   your own.
3. The built-in `kagent-tool-server` `RemoteMCPServer` (shipped by
   kagent) — used for the `k8s_*` tool family. The agent does not need a
   custom MCP server because the operator surface is just Kubernetes
   resources.

## Apply

```bash
kubectl apply -f kagent/agent-ironic-expert.yaml
kubectl -n kagent get agent ironic-kog-expert
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
