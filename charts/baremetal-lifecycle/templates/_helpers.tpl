{{/*
baremetal-lifecycle chart helpers
*/}}
{{- define "baremetal-lifecycle.nodeApiVersion" -}}baremetal.ogen.krateo.io/v1alpha1{{- end -}}
{{- define "baremetal-lifecycle.nodeNamespace" -}}
{{- if .Values.nodeNamespace -}}
{{- .Values.nodeNamespace -}}
{{- else -}}
{{- .Release.Namespace -}}
{{- end -}}
{{- end -}}
{{/*
Name of the NodeConfiguration the rendered Node CR points at. Always a namespace-scoped
singleton (default: ironic-endpoint) installed by `make restdef-up`. NEVER bundled with the
per-node release - if it were, helm uninstall would race RDC's delete handler and orphan the
external Ironic node (see manifests/nodeconfiguration-ironic.yaml).
*/}}
{{- define "baremetal-lifecycle.configName" -}}
{{- if and .Values.configurationRef .Values.configurationRef.name -}}
{{- .Values.configurationRef.name -}}
{{- else -}}
ironic-endpoint
{{- end -}}
{{- end -}}

{{/*
Current Ironic provision_state of the Node, read live via the Helm `lookup` function.
composition-dynamic-controller re-evaluates this on every reconcile, so the per-state
transition templates render the resource appropriate to the node's current state.
Returns "" when the Node CR doesn't exist yet or during client-side `helm template`.
*/}}
{{- define "baremetal-lifecycle.provisionState" -}}
{{- $node := lookup (include "baremetal-lifecycle.nodeApiVersion" .) "Node" (include "baremetal-lifecycle.nodeNamespace" .) .Values.nodeName -}}
{{- if $node -}}{{- dig "status" "provision_state" "" $node -}}{{- end -}}
{{- end -}}
