{{/*
Expand the chart name.
*/}}
{{- define "ankole-agent.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create the fully qualified application name.
*/}}
{{- define "ankole-agent.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Common labels.
*/}}
{{- define "ankole-agent.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "ankole-agent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{- define "ankole-agent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ankole-agent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "ankole-agent.componentLabels" -}}
{{ include "ankole-agent.labels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "ankole-agent.componentSelectorLabels" -}}
{{ include "ankole-agent.selectorLabels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
Component names.
*/}}
{{- define "ankole-agent.controlPlaneName" -}}
{{- printf "%s-control-plane" (include "ankole-agent.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ankole-agent.workerName" -}}
{{- printf "%s-worker" (include "ankole-agent.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ankole-agent.postgresqlName" -}}
{{- printf "%s-postgresql" (include "ankole-agent.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Render an image reference. A digest takes precedence over the mutable tag.
*/}}
{{- define "ankole-agent.image" -}}
{{- if .image.digest -}}
{{- printf "%s@%s" .image.repository .image.digest -}}
{{- else -}}
{{- printf "%s:%s" .image.repository (required "image.tag is required when image.digest is empty" .image.tag) -}}
{{- end -}}
{{- end -}}

{{/*
Bootstrap Secret and generated values.
*/}}
{{- define "ankole-agent.bootstrapSecretName" -}}
{{- default (printf "%s-bootstrap" (include "ankole-agent.fullname" .)) .Values.secrets.existingSecret | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ankole-agent.preservedSecretValue" -}}
{{- if .explicit -}}
{{- .explicit -}}
{{- else -}}
{{- $secret := lookup "v1" "Secret" .root.Release.Namespace (include "ankole-agent.bootstrapSecretName" .root) -}}
{{- if and $secret (hasKey $secret.data .key) -}}
{{- index $secret.data .key | b64dec -}}
{{- else -}}
{{- randAlphaNum .length -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "ankole-agent.ankoleSecretBase" -}}
{{- include "ankole-agent.preservedSecretValue" (dict "root" . "key" "ANKOLE_SECRET_BASE" "explicit" .Values.secrets.ankoleSecretBase "length" 64) -}}
{{- end -}}

{{- define "ankole-agent.workerAuthKey" -}}
{{- include "ankole-agent.preservedSecretValue" (dict "root" . "key" "ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY" "explicit" .Values.secrets.workerAuthKey "length" 48) -}}
{{- end -}}

{{- define "ankole-agent.postgresqlPassword" -}}
{{- include "ankole-agent.preservedSecretValue" (dict "root" . "key" "POSTGRES_PASSWORD" "explicit" .Values.secrets.postgresqlPassword "length" 32) -}}
{{- end -}}

{{/*
Worker Agent Home PVC.
*/}}
{{- define "ankole-agent.agentsClaimName" -}}
{{- default (printf "%s-agents" (include "ankole-agent.fullname" .)) .Values.worker.agents.persistence.existingClaim | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Service account.
*/}}
{{- define "ankole-agent.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "ankole-agent.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Reject values that violate deployment contracts.
*/}}
{{- define "ankole-agent.validateValues" -}}
{{- if not (has "ReadWriteMany" .Values.worker.agents.persistence.accessModes) -}}
{{- fail "worker.agents.persistence.accessModes must include ReadWriteMany because Agent Home is shared worker state" -}}
{{- end -}}
{{- if and (not .Values.postgresql.enabled) (not .Values.secrets.existingSecret) (not .Values.secrets.databaseURL) -}}
{{- fail "set secrets.databaseURL or secrets.existingSecret when postgresql.enabled is false" -}}
{{- end -}}
{{- end -}}
