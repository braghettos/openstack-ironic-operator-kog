{{- define "baremetal-host.nodeApiVersion" -}}baremetal.ogen.krateo.io/v1alpha1{{- end -}}
{{- define "baremetal-host.nodeNamespace" -}}
{{- if .Values.nodeNamespace -}}{{- .Values.nodeNamespace -}}{{- else -}}{{- .Release.Namespace -}}{{- end -}}
{{- end -}}
{{- define "baremetal-host.configName" -}}
{{- if and .Values.configurationRef .Values.configurationRef.name -}}{{- .Values.configurationRef.name -}}{{- else -}}ironic-endpoint{{- end -}}
{{- end -}}

{{/* True when the host is "detached" — all transition templates should short-circuit and
     render nothing. The Node + Port CRs stay (so hand-off works) but no NodeProvision /
     NodePower CRs are produced. Mirror of metal3's `detached` annotation. */}}
{{- define "baremetal-host.detached" -}}
{{- if .Values.detached -}}true{{- end -}}
{{- end -}}

{{/* Live provision_state of the Node via lookup. Empty when CR doesn't exist yet. */}}
{{- define "baremetal-host.provisionState" -}}
{{- $node := lookup (include "baremetal-host.nodeApiVersion" .) "Node" (include "baremetal-host.nodeNamespace" .) .Values.nodeName -}}
{{- if $node -}}{{- dig "status" "provision_state" "" $node -}}{{- end -}}
{{- end -}}

{{/* Live power_state of the Node via lookup. */}}
{{- define "baremetal-host.powerState" -}}
{{- $node := lookup (include "baremetal-host.nodeApiVersion" .) "Node" (include "baremetal-host.nodeNamespace" .) .Values.nodeName -}}
{{- if $node -}}{{- dig "status" "power_state" "" $node -}}{{- end -}}
{{- end -}}

{{/* inspection_finished_at via lookup — used to gate provide on completed inspect. */}}
{{- define "baremetal-host.inspectionFinishedAt" -}}
{{- $node := lookup (include "baremetal-host.nodeApiVersion" .) "Node" (include "baremetal-host.nodeNamespace" .) .Values.nodeName -}}
{{- if $node -}}{{- dig "status" "inspection_finished_at" "" $node -}}{{- end -}}
{{- end -}}

{{/* Translate spec.image into Ironic's instance_info shape. spec.image.root_device maps to
     instance_info.root_device, image.source -> image_source, etc. spec.networkData (the
     deployed OS's view of networking) flows to instance_info.network_data.
     configdrive is NOT here: it belongs on the provision-action body (NodeProvision.spec
     .configdrive, the canonical Ironic field per oas/ironic-provision.yaml), assembled by
     baremetal-host.configdrive. Setting instance_info.config_drive would be silently
     ignored — Ironic's deploy looks up node.instance_info.get('configdrive') (no underscore)
     but the recommended path is the provision body. */}}
{{- define "baremetal-host.instanceInfo" -}}
{{- $img := .Values.image | default dict -}}
{{- $ii := dict -}}
{{- with $img.source       }}{{ $_ := set $ii "image_source"   . }}{{ end -}}
{{- with $img.checksum     }}{{ $_ := set $ii "image_checksum" . }}{{ end -}}
{{- with $img.checksum_type}}{{ $_ := set $ii "image_checksum_algorithm" . }}{{ end -}}
{{- with $img.format       }}{{ $_ := set $ii "image_type" . }}{{ end -}}
{{- with $img.root_device  }}{{ $_ := set $ii "root_device" . }}{{ end -}}
{{- with .Values.networkData }}{{- if . }}{{ $_ := set $ii "network_data" . }}{{ end }}{{ end -}}
{{- toYaml $ii -}}
{{- end -}}

{{/* Assemble the Ironic configdrive dict from spec.configDrive. Empty (returns "") when none
     of metaData/userData/networkData is set, so callers can `if` on the result. Emits the
     canonical Ironic shape with snake_case keys: {meta_data, user_data, network_data} —
     this is the dict form documented for the provision PUT body (microversion >= 1.60).
     Used by transition-deploy.yaml. */}}
{{- define "baremetal-host.configdrive" -}}
{{- $cd := .Values.configDrive | default dict -}}
{{- if or $cd.metaData $cd.userData $cd.networkData -}}
{{- $out := dict "meta_data" ($cd.metaData | default dict) "user_data" ($cd.userData | default "") "network_data" ($cd.networkData | default dict) -}}
{{- toYaml $out -}}
{{- end -}}
{{- end -}}
