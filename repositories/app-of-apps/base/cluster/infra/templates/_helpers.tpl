{{- define "isEnvDefined" -}}
{{- if .Values.cluster_env -}}
{{- printf "true" }}
{{- else -}}
{{- printf "false" }}
{{- end -}}
{{- end -}}