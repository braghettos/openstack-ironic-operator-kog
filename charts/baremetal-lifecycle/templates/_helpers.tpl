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
{{/* Name of the generated NodeConfiguration CR (holds the Ironic endpoint header). */}}
{{- define "baremetal-lifecycle.configName" -}}
{{- if and .Values.configurationRef .Values.configurationRef.name -}}
{{- .Values.configurationRef.name -}}
{{- else -}}
{{- printf "%s-ironic-endpoint" .Release.Name -}}
{{- end -}}
{{- end -}}
