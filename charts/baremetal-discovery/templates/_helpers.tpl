{{/*
baremetal-discovery chart helpers (mirrors baremetal-lifecycle to share the same KOG
artifacts - Node CRD, NodeProvision CRD, NodeConfiguration singleton).
*/}}
{{- define "baremetal-discovery.nodeApiVersion" -}}baremetal.ogen.krateo.io/v1alpha1{{- end -}}
{{- define "baremetal-discovery.nodeNamespace" -}}
{{- if .Values.nodeNamespace -}}
{{- .Values.nodeNamespace -}}
{{- else -}}
{{- .Release.Namespace -}}
{{- end -}}
{{- end -}}
{{- define "baremetal-discovery.configName" -}}
{{- if and .Values.configurationRef .Values.configurationRef.name -}}
{{- .Values.configurationRef.name -}}
{{- else -}}
ironic-endpoint
{{- end -}}
{{- end -}}

{{/*
Current Ironic provision_state of the Node, read live via the Helm `lookup` function.
composition-dynamic-controller re-evaluates this on every reconcile.
Returns "" when the Node CR doesn't exist yet or during client-side `helm template`.
*/}}
{{- define "baremetal-discovery.provisionState" -}}
{{- $node := lookup (include "baremetal-discovery.nodeApiVersion" .) "Node" (include "baremetal-discovery.nodeNamespace" .) .Values.nodeName -}}
{{- if $node -}}{{- dig "status" "provision_state" "" $node -}}{{- end -}}
{{- end -}}
