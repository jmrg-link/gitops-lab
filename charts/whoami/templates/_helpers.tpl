{{- /*
@file charts/whoami/templates/_helpers.tpl

Plantillas con nombre que reutilizan los manifiestos. Un fichero que empieza por `_` no genera
ningún manifiesto: solo define bloques para `include`.
*/ -}}

{{- /*
Nombre de los recursos: `<release>-<chart>`, o solo `<release>` si ya contiene el nombre del
chart. Se corta a 63 caracteres, el límite de los nombres DNS en Kubernetes.
*/ -}}
{{- define "whoami.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- /*
Labels que eligen los pods del Deployment y del Service. El selector de un Deployment no se
puede cambiar después de crearlo, por eso aquí no va la versión.
*/ -}}
{{- define "whoami.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- /*
Labels comunes de todos los recursos: las de selección, la versión desplegada y quién los gestiona.
*/ -}}
{{- define "whoami.labels" -}}
{{ include "whoami.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}
