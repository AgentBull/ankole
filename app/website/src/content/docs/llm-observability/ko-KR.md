---
title: LLM observability
description: AIGateway LLM semantics가 포함된 선택적 cross-runtime Agent Turn trace를 OTLP/HTTP receiver로 export합니다.
section: User guide
order: 44
---

Ankole은 OpenTelemetry trace를 OpenTelemetry Protocol(OTLP) HTTP/protobuf로 export할 수 있습니다. 이 기능은 기본적으로 꺼져 있습니다. `observability.traces.provider`는 Turn root와 AIGateway LLM span에 추가할 vendor attributes를 선택합니다. AIGateway model Provider나 transport가 아니며 다른 OpenTelemetry span을 filter하지 않습니다. `langfuse`는 Langfuse v4 agent와 generation attributes, `langsmith`는 LangSmith compatibility attributes, `opentelemetry`는 범용 OpenTelemetry, `gen_ai.*`, Ankole attributes를 출력합니다.

활성화된 trace에는 model input과 output이 포함되며 tool argument와 result도 포함될 수 있습니다. Ankole은 credential, request header, 일반 caller metadata, 암호화된 reasoning과 tool field, 내부 `__ankole_*` field를 제거합니다. inline `data:` media는 byte count로 바꾸고 1 MiB를 초과하는 input 또는 output payload는 생략합니다. 그래도 receiver는 적절한 access control과 retention policy를 가진 trusted system이어야 합니다.

dispatch된 각 Agent Turn은 하나의 trace가 됩니다. `turn <event-type>` root span은 Langfuse의 agent observation이며 sanitize된 trigger event와 final reply를 포함합니다. Main Agent tool span과 AIGateway response span은 이 root의 child입니다. Background Job에는 `codex.turn`과 Codex tool span도 포함됩니다. Turn context가 없는 직접 AIGateway call은 계속 `ai_gateway.response`를 root로 사용합니다. Agent Computer는 protobuf OTLP batch를 authenticated Runtime Fabric RPC lane을 통해 보내므로 receiver credential은 control plane에만 남습니다.

## Langfuse 구성

다음 절차는 [Langfuse OpenTelemetry guide](https://langfuse.com/integrations/native/opentelemetry)와 [Langfuse v4 migration checklist](https://langfuse.com/integrations/native/opentelemetry/migration-to-v4)를 따릅니다.

1. Langfuse project의 **Settings → API Keys**에서 Public Key(`pk-lf-...`)와 Secret Key(`sk-lf-...`)를 가져옵니다.
2. **Console → AppConfigure → LLM observability**를 열고 Trace Provider에서 **Langfuse**를 선택합니다.
3. region에 맞는 base endpoint를 입력합니다. EU는 `https://cloud.langfuse.com/api/public/otel`, US는 `https://us.cloud.langfuse.com/api/public/otel`, Japan은 `https://jp.cloud.langfuse.com/api/public/otel`, HIPAA는 `https://hipaa.cloud.langfuse.com/api/public/otel`입니다. Self-hosted Langfuse 3.22.0 이상은 `https://<langfuse-host>/api/public/otel`을 사용합니다.
4. 다음 명령으로 줄바꿈이 없는 Basic Auth 값을 만듭니다.

   ```bash
   printf '%s' 'pk-lf-...:sk-lf-...' | base64 | tr -d '\n'
   ```

5. 인증 header 행을 두 개 추가합니다. 첫 번째 이름은 `Authorization`, 값은 `Basic <base64-value>`입니다. 두 번째 이름은 `x-langfuse-ingestion-version`, 값은 `4`입니다.
6. **Trace export**를 켜고 저장한 후 control plane을 다시 시작합니다.
7. 일반 Agent message를 하나 보내거나 Background Job을 하나 실행합니다. Langfuse에는 `turn <event-type>` agent root observation이 표시됩니다. Main Agent trace에는 `tool <name>`과 `ai_gateway.response` child가 있고, 각 response 아래에 `chat <model>` generation이 있습니다. Background Job에는 `codex.turn`과 Codex tool span도 있습니다. 직접 AIGateway request는 계속 `ai_gateway.response` root로 표시됩니다. provider native compaction 호출은 독립된 `compact <model>` generation으로 표시됩니다.

endpoint에 `/v1/traces`를 넣지 마십시오. Ankole이 `/v1/traces`를 추가하고 `application/x-protobuf`를 전송합니다. Langfuse의 이 endpoint는 OTLP/gRPC를 받지 않습니다. `x-langfuse-ingestion-version: 4`는 v4 real-time ingestion을 선택합니다. headers는 PostgreSQL에 암호화되어 저장됩니다.

Langfuse는 Console setting을 추가하지 않아도 새 trace를 trigger identity로 group화합니다. Ankole은 다음 규칙으로 `user.id`를 설정합니다.

- trusted human이 보낸 direct message Turn은 `principal:<principal_uid>`를 사용합니다.
- group Turn 또는 source channel이 있는 event Turn은 `channel:<signal_channel_id>`를 사용합니다.
- source channel이 없어도 trusted human trigger가 있는 Turn은 `principal:<principal_uid>`를 사용합니다.
- trusted human과 source channel이 모두 없는 Turn은 `user.id`를 생략합니다.

Turn에 속하지 않는 direct AIGateway request는 `principal:<authenticated_subject_uid>`를 사용합니다. Agent identity는 `ankole.principal.uid`, `ankole.principal.type`, filter 가능한 trace metadata에 별도로 유지됩니다. Main Agent conversation 또는 Background Job Codex session인 기존 Langfuse session은 바뀌지 않습니다.

이 identity mapping은 다섯 번째 AppConfigure value를 추가하지 않습니다. 위의 네 values는 계속 export와 OTLP receiver만 제어합니다. 업데이트한 control plane과 Agent Computer를 다시 시작한 후 생성한 span만 새 mapping을 사용합니다. 기존 Langfuse 데이터는 바뀌지 않습니다. control plane에 선택 사항인 `ANKOLE_ENV`와 `ANKOLE_VERSION`을 설정하면 각 trace에 Langfuse environment(소문자 영숫자와 `-`, `_`, 최대 40자)와 release가 붙습니다.

## LangSmith 구성

이 구성은 [LangSmith OpenTelemetry guide](https://docs.langchain.com/langsmith/trace-with-opentelemetry)와 [LangSmith announcement](https://www.langchain.com/blog/opentelemetry-langsmith)를 따릅니다.

1. **Console → AppConfigure → LLM observability**를 열고 Trace Provider에서 **LangSmith**를 선택합니다.
2. region에 맞는 base endpoint를 설정합니다. GCP US는 `https://api.smith.langchain.com/otel`, GCP EU는 `https://eu.api.smith.langchain.com/otel`, GCP APAC는 `https://apac.api.smith.langchain.com/otel`, AWS US는 `https://aws.api.smith.langchain.com/otel`, self-hosted는 `https://<langsmith-api-host>/api/v1/otel`입니다.
3. 인증 header에 `x-api-key`를 추가합니다. 필요한 경우 `Langsmith-Project`도 추가합니다. 생략하면 `default` Project를 사용합니다.
4. **Trace export**를 켜고 저장한 후 control plane을 다시 시작합니다.

AIGateway Response가 conversation에 속하면 `langsmith` provider는 conversation ID를 LangSmith 공식 `langsmith.trace.session_id`에 설정하고 `session.id`와 `gen_ai.conversation.id`에도 유지합니다.

## 다른 OTLP/HTTP receiver

다음 receiver에는 `observability.traces.provider=opentelemetry`를 사용합니다. base endpoint에 `/v1/traces`를 추가하지 마십시오.
Visual form에서 다음 Headers 열의 각 entry를 인증 header 한 행으로 추가하세요.

| Receiver | Endpoint | Headers |
|---|---|---|
| OpenTelemetry Collector | `http://<collector-host>:4318` | authentication이 필요 없으면 `{}` |
| VictoriaTraces single-node | `http://<victoria-traces>:10428/insert/opentelemetry` | trusted network에서 authentication proxy가 없으면 `{}` |
| VictoriaTraces cluster | `http://<vtinsert>:10481/insert/opentelemetry` | trusted network에서 authentication proxy가 없으면 `{}` |
| Honeycomb US / EU | `https://api.honeycomb.io` / `https://api.eu1.honeycomb.io` | `{"x-honeycomb-team":"<api-key>"}` |
| Grafana Cloud | stack의 OpenTelemetry connection tile에서 base endpoint 복사 | `{"Authorization":"Basic <base64(instance-id:access-policy-token)>"}` |

VictoriaTraces의 최종 path는 `/insert/opentelemetry/v1/traces`입니다. VictoriaTraces는 tenant authorization을 제공하지 않으므로 untrusted network에서는 vmauth 같은 authentication proxy를 사용하십시오. 자세한 내용은 [VictoriaTraces OTLP documentation](https://docs.victoriametrics.com/victoriatraces/data-ingestion/opentelemetry/)을 참조하십시오.

Grafana Cloud token에는 `traces:write`가 필요합니다. 자세한 내용은 [Honeycomb OTLP documentation](https://docs.honeycomb.io/send-data/opentelemetry)과 [Grafana Cloud OTLP documentation](https://grafana.com/docs/grafana-cloud/send-data/otlp/send-data-otlp/)을 참조하십시오. Provider 선택은 Turn root와 AIGateway LLM span만 enrich합니다. Worker tool span과 control plane의 다른 span은 vendor-neutral 상태로 같은 configured receiver에 전송됩니다.

설정 변경은 control-plane startup 때 한 번만 읽습니다. 비활성화하려면 `observability.traces.enabled`를 `false`로 설정하고 control plane을 다시 시작합니다. `OTEL_TRACES_EXPORTER` 또는 `OTEL_EXPORTER_OTLP_*`로 Ankole을 구성하지 마십시오. Ankole은 OpenTelemetry가 시작되기 전과 AppConfigure endpoint와 headers를 적용하기 전에 이 variables를 제거합니다. 이 exporter는 AppConfigure만 관리합니다.
