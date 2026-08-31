---
title: AppConfigure
description: Console에서 Ankole AppConfigure 런타임 설정을 관리하고 내장 키를 참조합니다.
section: User guide
order: 43
---

**Console → AppConfigure**에는 배포 인스턴스가 서비스 중일 때 관리자가 변경할 수 있는 설정이 있습니다. 예를 들어 대화 히스토리 압축, Agent 한도, 디렉터리 동기화 간격, 플러그인 스위치가 있습니다.

LLM 제공자, Identity Provider, 채팅 채널, 환경 변수는 각자 전용 Console 페이지가 있습니다. 여기에서 다시 구성하지 마세요.

## AppConfigure와 환경 변수

AppConfigure 설정은 PostgreSQL에 저장됩니다. 인스턴스가 실행되는 동안 Ankole 제품 동작을 제어합니다. 대부분의 변경은 이후 작업에 적용되며 새 배포가 필요하지 않습니다.

[배포 환경 변수](../environment-variables/)는 제어 플레인, PostgreSQL, Workers를 시작합니다. 하나를 변경한 후에는 영향을 받는 프로세스를 다시 시작하세요.

Skill, 명령줄 도구, 또는 MCP 서비스가 API 키 같은 사용자 지정 값이 필요하면 [Agent 환경 변수](../worker-env/)를 사용하세요.

## 설정 찾기

페이지는 관련 설정을 그룹으로 묶습니다. 키 또는 설명으로 검색하거나, 그룹을 열어 설정을 함께 볼 수 있습니다.

각 행은 다음 상태 중 하나를 가집니다:

- **편집 가능(Editable):** 행을 열어 여기에서 변경합니다.
- **읽기 전용(Read-only):** 행은 현재 상태를 표시하지만 여기에서 변경할 수 없습니다.
- **다른 곳에서 관리(Managed elsewhere):** 관리 링크를 따라 해당 설정을 소유한 Console 페이지로 이동합니다.

키는 설정의 안정적인 이름입니다. 설명은 설정이 제어하는 대상과 숫자가 사용하는 단위를 알려줍니다.

## 범위와 출처 이해하기

AppConfigure 페이지는 인스턴스 오버라이드를 변경합니다. **인스턴스 또는 Agent**로 표시된 키는 소유 기능이 단일 Agent에 대한 오버라이드를 저장할 수도 있게 하지만, 이 페이지는 Agent를 선택하거나 편집하지 않습니다.

Ankole이 Agent에 대해 이러한 설정 중 하나를 해석할 때 다음 순서를 사용합니다:

1. 현재 Agent 오버라이드;
2. 인스턴스 오버라이드;
3. 설치된 버전이 선언한 기본값.

AppConfigure 목록에는 인스턴스 오버라이드 또는 버전 기본값이 표시됩니다. **Reset to default**는 인스턴스 오버라이드를 제거합니다. 그러면 자체 오버라이드가 없는 모든 Agent가 버전 기본값을 사용합니다.

## 설정 변경

1. 설정 또는 설정 그룹을 엽니다.
2. 필드 설명을 읽고 범위와 단위를 확인합니다.
3. 필요한 값을 변경하고 저장합니다.
4. 목록으로 돌아와 행에 오버라이드가 표시되는지 확인합니다.

일반 설정은 전용 양식을 사용합니다. 일부 고급 설정은 JSON 편집기를 사용합니다. 기존 필드 구조를 유지하고 이해하지 못하는 필드를 제거하지 마세요.

대부분의 변경은 이후 작업에 적용됩니다. 페이지가 변경 사항이 다음 시작 시 적용된다고 표시하면 적절한 시점에 제어 플레인을 다시 시작하세요.

## 설정 초기화

사용자 지정 값이 더 이상 필요하지 않으면 설정을 열고 **Reset to default**를 선택하세요. 이렇게 하면 저장된 오버라이드가 제거되고 Ankole이 설치된 버전이 선언한 기본값을 사용하게 됩니다.

초기화는 현재 기본값을 사용자 지정 값으로 입력하는 것과 다릅니다. 초기화는 이후 버전에서 변경된 기본값을 따릅니다. 저장된 사용자 지정 값은 그렇지 않습니다.

## 현재 내장 AppConfigure 키

다음 AppConfigure 키는 Ankole에 내장되어 있습니다. Control Plane Plugin이 더 많은 키를 등록할 수 있습니다. 현재 인스턴스의 **AppConfigure** 페이지가 권위 있는 목록입니다.

### Agent 런타임

| 키 | 범위 | 용도 |
|---|---|---|
| `ai_agent.max_iterations` | 인스턴스 또는 Agent | Agent 한 턴의 최대 모델 반복 수 |
| `ai_agent.max_output_tokens` | 인스턴스 또는 Agent | 단일 모델 응답의 출력 토큰 상한 |
| `ai_agent.inactivity_timeout_ms` | 인스턴스 또는 Agent | 턴을 종료하기 전에 비활성 모델 또는 제공자를 기다리는 시간 |
| `ai_agent.library.agent_plugin_defaults` | 인스턴스 | Agent Plugin의 기본 활성화 상태 |
| `ai_agent.library.skill_defaults` | 인스턴스 | Skill의 기본 활성화 상태 |

### Workflow

| 키 | 범위 | 용도 |
|---|---|---|
| `workflow.max_concurrency_per_run` | 인스턴스 | Workflow run 하나가 요청할 수 있는 최대 task 동시성. 기본값은 `8`, 범위는 `1`–`32` |
| `workflow.max_running_per_agent` | 인스턴스 | Agent 하나의 모든 Workflow에서 동시에 실행할 수 있는 task 수. 기본값은 `8`, 범위는 `1`–`64` |
| `workflow.max_agent_calls_per_run` | 인스턴스 | Workflow run 하나가 만들 수 있는 총 `agent()` 호출 수. 기본값은 `256`, 범위는 `1`–`1,024` |

Workflow 생성 요청은 이 상한을 높일 수 없습니다. 요청한 `concurrency`나 `max_agent_calls`가 더 높으면 Ankole이 배포 상한으로 낮추어 저장합니다. 작업 분할과 결과 확인 방법은 [Workflows](../workflows/)를 참조하세요.

### Brain

| 키 | 범위 | 용도 |
|---|---|---|
| `brain.enabled` | 인스턴스 | Brain 검색, 학습, 유지 관리를 활성화합니다. 비활성화해도 저장된 지식은 유지됩니다. |
| `brain.maintainer_agent_uid` | 인스턴스 | Brain 유지보수를 담당하는 활성 Agent입니다. 모든 Brain 모델 호출은 이 Agent의 ID로 실행되고 사용량도 이 Agent에 귀속됩니다. 비활성화하면 다시 활성화하거나 교체할 때까지 해당 호출과 로컬 URL 가져오기가 중지됩니다. Agent 페이지에서 `light`, `heavy`, `web_fetch` profile을 편집합니다. |
| `brain.embedding_model` | 인스턴스 | 벡터 검색에 사용할 Provider, 모델, 차원 수입니다. 비어 있으면 벡터 검색을 비활성화합니다. |
| `brain.rerank_model` | 인스턴스 | 검색 결과 rerank에 사용할 Provider와 모델입니다. 비어 있으면 융합 결과 순서를 유지합니다. |
| `brain.search_tokenizer` | 인스턴스 | BM25 tokenizer: `icu`, `jieba`, `lindera_japanese`, `lindera_korean`. 변경 후에는 BM25 index를 다시 만들어야 합니다. |
| `brain.chunking` | 인스턴스 | Source chunk 크기, overlap, 입력 상한입니다. |
| `brain.forgetting` | 인스턴스 | 지식 종류별 감쇠 반감기와 soft-delete purge 간격입니다. |
| `brain.dreaming_task_cron` | 인스턴스 | 정기 지식 통합 schedule입니다. |
| `brain.self_healing_task_cron` | 인스턴스 | 오래된 chunk, embedding, 검색 index projection을 다시 만드는 schedule입니다. |
| `brain.signal_channel_batch_idle_time` | 인스턴스 | 대기 중인 chat message가 학습에 들어가기 전까지의 idle 초입니다. 대화 종료 시에도 학습을 시작합니다. |
| `brain.skill_learning_enabled` | 인스턴스 | Skill lesson 학습과 전달을 활성화합니다. 비활성화하면 저장된 lesson은 유지되지만 제공되지 않습니다. |
| `brain.skill_learning_reflection_threshold` | 인스턴스 | Agent 하나가 Skill lesson reflection을 시작하기 전에 쌓아야 하는, 아직 소비되지 않은 Signal Job 수입니다. 최솟값은 `2`입니다. |

지식 동작과 모델 요구 사항은 [Brain](../brain/)을 참조하십시오. Skill과 함께 제공되는 lesson은 [Skill lessons](../skill-lessons/)를 참조하십시오.

### AI Gateway 및 observability

| 키 | 범위 | 용도 |
|---|---|---|
| `ai_gateway.compaction` | 인스턴스 | 대화 히스토리 자동 압축 정책 |
| `observability.traces.enabled` | 인스턴스 | 다음 control-plane startup에서 process-wide OpenTelemetry export를 활성화할지 여부 |
| `observability.traces.provider` | 인스턴스 | `langfuse`, `langsmith` 또는 범용 `opentelemetry` trace의 semantic projection |
| `observability.traces.otlp_endpoint` | 인스턴스 | optional trace의 base OTLP/HTTP endpoint |
| `observability.traces.otlp_headers` | 인스턴스 | optional trace의 암호화된 authentication header |

Langfuse, LangSmith, VictoriaTraces 및 다른 OTLP/HTTP receiver 구성은 [LLM observability](../llm-observability/)를 참조하십시오.

### Identity, 플러그인 및 인스턴스 기본값

| 키 | 범위 | 용도 |
|---|---|---|
| `principals.identity_providers.active` | 인스턴스, 읽기 전용 | 관리자 로그인에 사용 가능한 Identity 소스; Identity Provider 페이지에서 관리 |
| `principals.identity_providers.directory_full_sync_interval_hours` | 인스턴스 | 전체 조직 디렉터리 동기화 간격 |
| `plugins.enabled_ids` | 인스턴스 | 다음 시작 시 활성화할 Control Plane Plugin |
| `system.timezone` | 인스턴스 | 스케줄 및 기타 제어 플레인 기능의 기본 시간대 |
| `i18n.default_locale` | 인스턴스 | Ankole 인터페이스의 기본 언어 |

### Workers, 웹 읽기 및 보안

| 키 | 범위 | 용도 |
|---|---|---|
| `runtime_fabric.worker_auth_key` | 인스턴스, 읽기 전용 | 제어 플레인과 Workers 간 인증 키; 시스템이 생성하고 유지 관리 |
| `agent_computer.background_agent_job.max_turns_per_worker` | 인스턴스 | 각 Worker에서의 최대 동시 Background Agent Job 턴 수 |
| `worker.rendered_fetch_idle_ttl_ms` | 인스턴스 또는 Agent | 내장 `web_fetch` 렌더링 폴백의 유휴 수명 |
| `security.ssrf_filter` | 인스턴스 또는 Agent | 모델 제어 fetch가 private, loopback, link-local, CGNAT 주소를 거부할지 여부 |

이 설정이 꺼져 있어도 클라우드 메타데이터 주소는 거부됩니다.

### 최초 실행 상태

| 키 | 범위 | 용도 |
|---|---|---|
| `setup.bootstrap_activation_code` | 인스턴스, 읽기 전용 | 최초 실행 설정 페이지용 임시 활성화 코드 |
| `setup.completed` | 인스턴스, 읽기 전용 | 이 인스턴스가 최초 실행 설정을 완료했는지 여부 |

최초 실행 설정 플로우가 이러한 키를 소유합니다. 활성화 코드를 읽으려면 `kit show bootstrap-activation-code`를 실행하세요. AppConfigure 페이지에서 이러한 키를 편집하지 마세요.

## 암호화된 설정

Ankole은 credential 설정을 암호화된 형태로 저장하고 목록과 편집기에 마스크를 표시합니다. 마스크를 저장하면 현재 값이 유지됩니다. 새 내용을 입력하면 대체됩니다.

**Reveal**은 현재 값을 확인해야 할 때만 사용하세요. 공개된 credential을 채팅, 스크린샷, 티켓에 복사하지 마세요.
