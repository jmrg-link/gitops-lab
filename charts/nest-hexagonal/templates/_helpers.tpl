{{- /*
@file charts/nest-hexagonal/templates/_helpers.tpl

Plantillas con nombre que reutilizan los manifiestos.
*/ -}}

{{- /*
Nombre de los recursos: `<release>-<chart>`, o solo `<release>` si ya contiene el nombre del
chart, recortado a 63 caracteres.
*/ -}}
{{- define "nest.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- /*
Labels que eligen los pods; sin versión, porque el selector de un Deployment no cambia.
*/ -}}
{{- define "nest.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- /*
Labels comunes de todos los recursos.
*/ -}}
{{- define "nest.labels" -}}
{{ include "nest.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}
