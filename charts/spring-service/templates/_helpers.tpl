{{- define "spring-service.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "spring-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "spring-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "spring-service.labels" -}}
{{ include "spring-service.selectorLabels" . }}
app.kubernetes.io/part-of: gateways
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "spring-service.image" -}}
{{- required "image.repository is required" .Values.image.repository -}}:{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end -}}
