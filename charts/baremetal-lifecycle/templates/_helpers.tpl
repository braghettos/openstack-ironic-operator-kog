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
