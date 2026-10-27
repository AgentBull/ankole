---
title: LLM observability
description: AIGateway LLM semantics가 포함된 선택적 cross-runtime Agent Turn trace를 OTLP/HTTP receiver로 export합니다.
section: User guide
order: 44
---

Ankole은 OpenTelemetry Protocol(OTLP) HTTP/protobuf 형식으로 OpenTelemetry 트레이스를 내보낼 수 있으며, 기본 상태는 비활성화되어 있습니다. `observability.traces.provider` 설정은 Turn 루트 span과 AIGateway LLM span에 어떤 벤더 전용 속성을 덧붙일지 결정합니다. 이는 AIGateway 모델 Provider나 전송 계층 설정이 아니며, 다른 OpenTelemetry span을 필터링하지도 않습니다. 값에 따라 `langfuse`는 Langfuse v4 에이전트 및 생성(generation) 속성을, `langsmith`는 LangSmith 호환 속성을, `opentelemetry`는 범용 OpenTelemetry·`gen_ai.*`·Ankole 속성을 기록합니다.

트레이스 내보내기를 켜면 모델 입력과 출력은 물론 도구 인수와 실행 결과까지 함께 전송될 수 있습니다. 이때 Ankole은 자격 증명, 요청 헤더, 일반 호출자 메타데이터, 암호화된 추론·도구 필드, 내부 `__ankole_*` 필드를 제거하며, 인라인 `data:` 미디어는 바이트 수로 치환하고 1 MiB를 넘는 입출력 페이로드는 생략합니다. 그렇더라도 수신 시스템(receiver)은 적절한 접근 제어와 보관 정책을 갖춘 신뢰할 수 있는 환경이어야 합니다.

디스패치된 각 Agent Turn은 하나의 트레이스로 기록됩니다. 루트 span인 `turn <event-type>`은 Langfuse에서 에이전트 observation으로 표시되며, 민감 정보가 제거된 트리거 이벤트와 최종 응답을 담습니다. Main Agent의 도구 span과 AIGateway 응답 span은 이 루트 span의 하위에 연결되고, Background Job에서는 `codex.turn`과 Codex 도구 span도 함께 포함됩니다. 반면 Turn 컨텍스트 없이 직접 호출한 AIGateway 요청은 `ai_gateway.response`를 루트 span으로 사용합니다. 또한 Agent Computer는 인증된 Runtime Fabric RPC 경로를 통해 protobuf OTLP 배치를 전달하므로, 수신 시스템의 자격 증명은 항상 control plane 내부에만 머뭅니다.

## Langfuse 구성

아래 절차는 [Langfuse OpenTelemetry guide](https://langfuse.com/integrations/native/opentelemetry)와 [Langfuse v4 migration checklist](https://langfuse.com/integrations/native/opentelemetry/migration-to-v4)를 기준으로 합니다.

1. Langfuse 프로젝트의 **Settings → API Keys**에서 Public Key(`pk-lf-...`)와 Secret Key(`sk-lf-...`)를 발급받습니다.
2. **Console → AppConfigure → LLM observability**를 열고 Trace Provider에서 **Langfuse**를 선택합니다.
3. 리전에 맞는 기본 엔드포인트를 입력합니다. EU는 `https://cloud.langfuse.com/api/public/otel`, US는 `https://us.cloud.langfuse.com/api/public/otel`, Japan은 `https://jp.cloud.langfuse.com/api/public/otel`, HIPAA는 `https://hipaa.cloud.langfuse.com/api/public/otel`이며, 자체 호스팅(Self-hosted) Langfuse 3.22.0 이상은 `https://<langfuse-host>/api/public/otel`을 사용합니다.
4. 다음 명령으로 줄바꿈 없는 Basic Auth 인코딩 문자열을 생성합니다.

   ```bash
   printf '%s' 'pk-lf-...:sk-lf-...' | base64 | tr -d '\n'
   ```

5. 인증 헤더 행을 두 개 추가합니다. 첫 번째 행에는 이름 `Authorization`과 값 `Basic <base64-value>`를 입력하고, 두 번째 행에는 이름 `x-langfuse-ingestion-version`과 값 `4`를 입력합니다.
6. **Trace export**를 켜고 설정을 저장한 뒤 control plane을 다시 시작합니다.
7. 일반 Agent 메시지를 하나 보내거나 Background Job을 하나 실행해 동작을 확인합니다. Langfuse에 `turn <event-type>` 에이전트 루트 observation이 나타나며, Main Agent 트레이스 아래에는 `tool <name>`과 `ai_gateway.response` 하위 항목이, 각 응답 아래에는 `chat <model>` generation이 기록됩니다. Background Job에는 `codex.turn`과 Codex 도구 span도 함께 표시됩니다. 직접 호출한 AIGateway 요청은 `ai_gateway.response` 루트로 기록되며, Provider의 네이티브 압축(compaction) 호출은 독립된 `compact <model>` generation으로 표시됩니다.

엔드포인트 주소 끝에 `/v1/traces`를 직접 붙이지 마십시오. Ankole이 자동으로 `/v1/traces` 경로를 붙여 `application/x-protobuf` 형식으로 전송합니다(Langfuse의 해당 엔드포인트는 OTLP/gRPC를 받지 않습니다). `x-langfuse-ingestion-version: 4` 헤더를 지정하면 v4 실시간 수집 경로가 적용되며, 입력한 헤더 값은 PostgreSQL에 암호화되어 저장됩니다.

Langfuse는 트리거 주체를 기준으로 트레이스를 묶어 보여주며, Ankole은 다음 규칙에 따라 `user.id`를 기록합니다.

- 신뢰된 사용자(human)가 보낸 다이렉트 메시지 Turn에는 `principal:<principal_uid>`를 기록합니다.
- 그룹 Turn이나 원본 Conversation이 있는 이벤트 Turn에는 `channel:<conversation_uuid>`를 기록합니다.
- 원본 Conversation이 없더라도 신뢰된 사용자 트리거가 있는 Turn에는 `principal:<principal_uid>`를 기록합니다.
- 신뢰된 사용자와 원본 Conversation이 모두 없는 Turn에서는 `user.id`를 생략합니다.

Turn 바깥에서 직접 호출한 AIGateway 요청에는 `principal:<authenticated_subject_uid>`가 사용됩니다. 실행 주체인 Agent 정보는 `ankole.principal.uid`, `ankole.principal.type` 및 필터링 가능한 트레이스 메타데이터에 기록되며, Langfuse의 세션 단위는 Main Agent 대화 또는 Background Job의 Codex 세션에 해당하는 conversation으로 매핑됩니다.

여기서 `channel:` 접두사는 관측 전송 계약의 일부이며, 뒤따르는 값은 외부 채팅 플랫폼의 채널 ID가 아니라 Ankole의 공개 Conversation UUID입니다.

선택 사항으로 control plane에 `ANKOLE_ENV`와 `ANKOLE_VERSION`을 설정하면, 각 트레이스에 Langfuse 환경 이름(소문자 영숫자와 `-`, `_` 조합, 최대 40자)과 릴리스 버전이 함께 태깅됩니다.

## LangSmith 구성

아래 절차는 [LangSmith OpenTelemetry guide](https://docs.langchain.com/langsmith/trace-with-opentelemetry)와 [LangSmith announcement](https://www.langchain.com/blog/opentelemetry-langsmith)를 기준으로 합니다.

1. **Console → AppConfigure → LLM observability**를 열고 Trace Provider에서 **LangSmith**를 선택합니다.
2. 리전에 맞는 기본 엔드포인트를 입력합니다. GCP US는 `https://api.smith.langchain.com/otel`, GCP EU는 `https://eu.api.smith.langchain.com/otel`, GCP APAC는 `https://apac.api.smith.langchain.com/otel`, AWS US는 `https://aws.api.smith.langchain.com/otel`이며, 자체 호스팅 환경은 `https://<langsmith-api-host>/api/v1/otel`을 사용합니다.
3. 인증 헤더에 `x-api-key`를 추가하고, 필요에 따라 `Langsmith-Project`도 함께 지정합니다(생략하면 `default` 프로젝트로 전송됩니다).
4. **Trace export**를 켜고 설정을 저장한 뒤 control plane을 다시 시작합니다.

AIGateway Response가 특정 conversation에 속해 있으면, `langsmith` 프로바이더는 해당 conversation ID를 LangSmith 공식 속성인 `langsmith.trace.session_id`에 기록하는 동시에 `session.id`와 `gen_ai.conversation.id`에도 함께 남깁니다.

## 다른 OTLP/HTTP receiver

아래 수신 시스템에는 `observability.traces.provider=opentelemetry`를 사용하십시오. 기본 엔드포인트 끝에 `/v1/traces`를 붙이지 마시고, 입력 폼에서는 표의 Headers 열에 적힌 항목을 각각 인증 헤더 행으로 추가하십시오.

| Receiver | Endpoint | Headers |
|---|---|---|
| OpenTelemetry Collector | `http://<collector-host>:4318` | 별도 인증이 필요 없으면 `{}` |
| VictoriaTraces single-node | `http://<victoria-traces>:10428/insert/opentelemetry` | 신뢰할 수 있는 내부망이고 인증 프록시가 없으면 `{}` |
| VictoriaTraces cluster | `http://<vtinsert>:10481/insert/opentelemetry` | 신뢰할 수 있는 내부망이고 인증 프록시가 없으면 `{}` |
| Honeycomb US / EU | `https://api.honeycomb.io` / `https://api.eu1.honeycomb.io` | `{"x-honeycomb-team":"<api-key>"}` |
| Grafana Cloud | 스택의 OpenTelemetry 연결 타일에서 기본 엔드포인트 복사 | `{"Authorization":"Basic <base64(instance-id:access-policy-token)>"}` |

VictoriaTraces에 최종 전송되는 경로는 `/insert/opentelemetry/v1/traces`가 됩니다. VictoriaTraces 자체에는 테넌트 인가 기능이 없으므로, 신뢰할 수 없는 네트워크 구간에서는 vmauth 같은 인증 프록시를 앞단에 두십시오. 자세한 내용은 [VictoriaTraces OTLP documentation](https://docs.victoriametrics.com/victoriatraces/data-ingestion/opentelemetry/)을 참조하십시오.

Grafana Cloud 토큰에는 `traces:write` 권한이 필요합니다. 자세한 설정 방법은 [Honeycomb OTLP documentation](https://docs.honeycomb.io/send-data/opentelemetry)과 [Grafana Cloud OTLP documentation](https://grafana.com/docs/grafana-cloud/send-data/otlp/send-data-otlp/)을 확인하십시오. Trace Provider 선택에 따른 벤더 속성 보강은 Turn 루트 span과 AIGateway LLM span에만 적용되며, Worker 도구 span과 그 밖의 control plane span은 벤더 중립적인 속성 그대로 동일한 수신 시스템에 함께 전송됩니다.

트레이스 설정은 control plane이 시작될 때 한 번만 읽어들입니다. 내보내기를 끄려면 `observability.traces.enabled`를 `false`로 바꾼 뒤 control plane을 재시작하십시오. 이때 `OTEL_TRACES_EXPORTER`나 `OTEL_EXPORTER_OTLP_*` 환경 변수로 Ankole을 설정하지 마십시오. Ankole은 OpenTelemetry가 기동되기 전, 그리고 AppConfigure의 엔드포인트와 헤더를 적용하기 전에 해당 환경 변수들을 모두 제거하며 오직 AppConfigure 설정으로만 exporter를 관리합니다.
