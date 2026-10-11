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

{{- define "ankole-agent.controlPlaneHeadlessName" -}}
{{- printf "%s-control-plane-headless" (include "ankole-agent.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ankole-agent.workerName" -}}
{{- printf "%s-worker" (include "ankole-agent.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ankole-agent.workerProvidersName" -}}
{{- printf "%s-worker-providers" (include "ankole-agent.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
The owner of Worker Pods, Secrets, and cache PVCs: `helm uninstall` deletes it,
and Kubernetes then deletes the Worker objects.
*/}}
{{- define "ankole-agent.agentWorkersOwnerName" -}}
{{- printf "%s-agent-workers" (include "ankole-agent.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Installation label of the Worker objects of this release.
*/}}
{{- define "ankole-agent.workerInstallation" -}}
{{- default .Release.Name .Values.worker.installation | lower | trunc 20 | trimSuffix "-" -}}
{{- end -}}

{{/*
Default Worker endpoint inside this cluster.
*/}}
{{- define "ankole-agent.workerRuntimeFabricEndpoint" -}}
{{- if .Values.worker.runtimeFabricEndpoint -}}
{{- .Values.worker.runtimeFabricEndpoint -}}
{{- else -}}
{{- printf "ws://%s:%v/runtime-fabric/worker" (include "ankole-agent.controlPlaneName" .) .Values.controlPlane.service.port -}}
{{- end -}}
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

{{- define "ankole-agent.releaseCookie" -}}
{{- include "ankole-agent.preservedSecretValue" (dict "root" . "key" "RELEASE_COOKIE" "explicit" .Values.secrets.releaseCookie "length" 64) -}}
{{- end -}}

{{- define "ankole-agent.postgresqlPassword" -}}
{{- include "ankole-agent.preservedSecretValue" (dict "root" . "key" "POSTGRES_PASSWORD" "explicit" .Values.secrets.postgresqlPassword "length" 32) -}}
{{- end -}}

{{/*
Control-plane file store PVC for files.store=fs.
*/}}
{{- define "ankole-agent.filesClaimName" -}}
{{- default (printf "%s-files" (include "ankole-agent.fullname" .)) .Values.files.persistence.existingClaim | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Service accounts: the control plane's, and the Workers' without permissions.
*/}}
{{- define "ankole-agent.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "ankole-agent.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "ankole-agent.workerServiceAccountName" -}}
{{- include "ankole-agent.workerName" . -}}
{{- end -}}

{{/*
Reject values that violate deployment contracts.
*/}}
{{- define "ankole-agent.validateValues" -}}
{{- range (include "ankole-agent.workerProvidersSeed" . | fromYaml).providers -}}
{{- $config := fromYaml .config -}}
{{- if and (dig "endpoints" "relayOrigin" "" $config) (gt (int $.Values.controlPlane.replicaCount) 1) -}}
{{- fail "a provider endpoints.relayOrigin requires one control-plane replica: the URL must reach the node that owns the relay" -}}
{{- end -}}
{{- end -}}
{{- if and (not .Values.worker.localPods) (not .Values.worker.providers) -}}
{{- fail "worker.localPods=false requires worker.providers: the generated provider runs Worker Pods in the release namespace" -}}
{{- end -}}
{{- if not (has .Values.worker.cache.type (list "pvc" "emptyDir")) -}}
{{- fail "worker.cache.type must be pvc or emptyDir" -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$" (include "ankole-agent.workerInstallation" .)) -}}
{{- fail "worker.installation (or the release name) must give lowercase letters, digits, and hyphens" -}}
{{- end -}}
{{- if and (not .Values.postgresql.enabled) (not .Values.secrets.existingSecret) (not .Values.secrets.databaseURL) -}}
{{- fail "set secrets.databaseURL or secrets.existingSecret when postgresql.enabled is false" -}}
{{- end -}}
{{- if not (has .Values.files.store (list "fs" "s3")) -}}
{{- fail "files.store must be fs or s3" -}}
{{- end -}}
{{- if and (eq .Values.files.store "fs") (gt (int .Values.controlPlane.replicaCount) 1) -}}
{{- fail "files.store=fs allows one control-plane replica; use files.store=s3 for more" -}}
{{- end -}}
{{- if and (eq .Values.files.store "s3") (or (not .Values.files.s3.bucket) (not .Values.files.s3.region)) -}}
{{- fail "files.s3.bucket and files.s3.region are required when files.store is s3" -}}
{{- end -}}
{{- end -}}

{{/*
Environment of the control-plane release. The migration init container runs
the same release, and its runtime configuration reads these variables too.
*/}}
{{- define "ankole-agent.controlPlaneEnv" -}}
# Workers fetch and deliver file bytes at the Pod that issued the
# relay URL, and the Erlang node name uses the same address.
- name: POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
- name: RELEASE_COOKIE
  valueFrom:
    secretKeyRef:
      name: {{ include "ankole-agent.bootstrapSecretName" . }}
      key: RELEASE_COOKIE
- name: ANKOLE_SECRET_BASE
  valueFrom:
    secretKeyRef:
      name: {{ include "ankole-agent.bootstrapSecretName" . }}
      key: ANKOLE_SECRET_BASE
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "ankole-agent.bootstrapSecretName" . }}
      key: DATABASE_URL
{{- if eq .Values.files.store "s3" }}
- name: ANKOLE_FILES_S3_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ include "ankole-agent.bootstrapSecretName" . }}
      key: ANKOLE_FILES_S3_ACCESS_KEY_ID
      optional: true
- name: ANKOLE_FILES_S3_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "ankole-agent.bootstrapSecretName" . }}
      key: ANKOLE_FILES_S3_SECRET_ACCESS_KEY
      optional: true
{{- end }}
{{- end }}
