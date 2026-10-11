{{- define "ankole-agent.agentsClaimName" -}}
{{- default (printf "%s-agents" (include "ankole-agent.fullname" .)) .Values.worker.agents.persistence.existingClaim -}}
{{- end -}}

{{- define "ankole-agent.defaultWorkerProviderConfig" -}}
{{- if .Values.worker.providerConfig -}}
{{- .Values.worker.providerConfig -}}
{{- else -}}
namespace: {{ .Release.Namespace | quote }}
ownerConfigMap: {{ include "ankole-agent.agentWorkersOwnerName" . | quote }}
serviceAccount: {{ include "ankole-agent.workerServiceAccountName" . | quote }}
storage:
  {{- if .Values.worker.storage }}
  {{- toYaml .Values.worker.storage | nindent 2 }}
  {{- else }}
  sharedClaim: {{ include "ankole-agent.agentsClaimName" . | quote }}
  {{- end }}
cache:
  {{- if eq .Values.worker.cache.type "pvc" }}
  claimTemplate:
    accessModes: [ReadWriteOnce]
    {{- with .Values.worker.cache.storageClass }}
    storageClassName: {{ . | quote }}
    {{- end }}
    resources:
      requests:
        storage: {{ .Values.worker.cache.size | quote }}
  {{- else }}
  sizeLimit: {{ .Values.worker.cache.size | quote }}
  {{- end }}
stopGraceSeconds: {{ .Values.worker.terminationGracePeriodSeconds }}
idleReleaseAfter: {{ .Values.worker.idleReleaseAfter | quote }}
podTemplate:
  spec:
    {{- with .Values.worker.runtimeClassName }}
    runtimeClassName: {{ . | quote }}
    {{- end }}
    {{- with .Values.imagePullSecrets }}
    imagePullSecrets:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.worker.nodeSelector }}
    nodeSelector:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.worker.tolerations }}
    tolerations:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.worker.affinity }}
    affinity:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    containers:
      - name: worker
        imagePullPolicy: {{ .Values.worker.image.pullPolicy }}
        {{- with .Values.worker.extraEnv }}
        env:
          {{- range $key, $value := . }}
          - name: {{ $key }}
            value: {{ $value | quote }}
          {{- end }}
        {{- end }}
        {{- with .Values.worker.resources }}
        resources:
          {{- toYaml . | nindent 10 }}
        {{- end }}
        {{- with .Values.worker.readinessProbe }}
        readinessProbe:
          {{- toYaml . | nindent 10 }}
        {{- end }}
        {{- with .Values.worker.livenessProbe }}
        livenessProbe:
          {{- toYaml . | nindent 10 }}
        {{- end }}
{{- end -}}
{{- end -}}

{{- define "ankole-agent.workerProvidersSeed" -}}
{{- if .Values.worker.providers -}}
{{- toYaml (dict "providers" .Values.worker.providers) -}}
{{- else -}}
{{- $config := include "ankole-agent.defaultWorkerProviderConfig" . -}}
{{- $parsed := fromYaml $config -}}
{{- $legacy := and (eq (get $parsed "namespace") .Release.Namespace) (eq (dig "storage" "sharedClaim" "" $parsed) (include "ankole-agent.agentsClaimName" .)) -}}
{{- toYaml (dict "providers" (list (dict "provider_id" "kubernetes" "kind" "kubernetes" "display_name" "Local Kubernetes" "is_default" true "legacy_agents" $legacy "config" $config))) -}}
{{- end -}}
{{- end -}}
