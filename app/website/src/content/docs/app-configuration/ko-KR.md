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

[배포 환경 변수](../environment-variables/)는 제어 플레인과 PostgreSQL을 시작하고 Worker 백엔드를 구성합니다. 하나를 변경한 후에는 영향을 받는 프로세스를 다시 시작하세요.

Skill, 명령줄 도구, 또는 MCP 서비스가 API 키 같은 사용자 지정 값이 필요하면 [Agent 환경 변수](../worker-env/)를 사용하세요.

## 설정 찾기

페이지는 관련 설정을 그룹으로 묶습니다. 키 또는 설명으로 검색하거나, 그룹을 열어 설정을 함께 볼 수 있습니다.

각 행은 다음 상태 중 하나를 가집니다:

- **편집 가능(Editable):** 행을 열어 여기에서 변경합니다.
- **읽기 전용(Read-only):** 행은 현재 상태를 표시하지만 여기에서 변경할 수 없습니다.
- **다른 곳에서 관리(Managed elsewhere):** 관리 링크를 따라 해당 설정을 소유한 Console 페이지로 이동합니다.

키는 설정의 안정적인 이름입니다. 설명은 설정이 제어하는 대상과 숫자가 사용하는 단위를 알려줍니다.

## 범위와 출처 이해하기

설정 키는 **사이트** 또는 **테넌트** 범위를 갖습니다. 사이트 키는 공유 인프라를, 테넌트 키는 선택한 테넌트의 동작을 제어합니다. Console은 사이트 기본값과 테넌트 재정의를 따로 표시합니다. Agent 재정의는 지원하지 않습니다.

사이트 키는 저장된 값, 버전 기본값 순으로 해석합니다. 테넌트 키는 테넌트 재정의, 같은 키의 사이트 기본값, 버전 기본값 순으로 해석합니다. **Reset to default**는 선택한 범위의 재정의를 제거합니다. Source 열은 적용된 값의 출처를 표시합니다.

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
| `ai_agent.max_iterations` | 테넌트 | Agent 한 턴의 최대 모델 반복 수 |
| `ai_agent.max_output_tokens` | 테넌트 | 단일 모델 응답의 출력 토큰 상한 |
| `ai_agent.inactivity_timeout_ms` | 테넌트 | 턴을 종료하기 전에 비활성 모델 또는 제공자를 기다리는 시간 |
| `ai_agent.library.agent_plugin_defaults` | 테넌트 | Agent Plugin의 기본 활성화 상태 |
| `ai_agent.library.skill_defaults` | 테넌트 | Skill의 기본 활성화 상태 |
| `agent_computer.background_agent_job.max_running_per_agent` | 테넌트 | Agent당 동시 실행 가능한 최대 BackgroundAgentJob 수; 기본값 `3`, 유효 범위 `1`–`64` |
| `automation_jobs.max_running_per_agent` | 테넌트 | Agent당 동시 실행 가능한 최대 자동화 스크립트 수; 기본값 `10`, 유효 범위 `1`–`64` |

### Pod, Base 및 Applet

| 키 | 범위 | 용도 |
|---|---|---|
| `pod.allow_external_guests` | 테넌트 | 초대된 외부 게스트가 공유된 Pod 페이지에 접근하도록 허용; 기본값 `true` |
| `pod.applet.limits` | 테넌트 | Applet 호출 한도(기본값 `timeout_ms: 60000`, `heap_mb: 128`) |
| `pod.base.limits` | 테넌트 | Base 쿼리 및 레코드 한도(기본값 `query_rows: 1000`, `record_bytes: 1000000`, `group_count: 1000`, `statement_timeout_ms: 5000`) |
| `pod.trash_retention_days` | 테넌트 | 삭제된 페이지를 자동 영구 정리하기 전까지 보관하는 양의 정수 일수(기본값 `30`), 또는 자동 정리 없이 보관하는 `"unlimited"` |
| `pod.ot_replay_window` | 테넌트 | OT 재생을 위해 보관하는 최근 문서 변경 배치 수; 기본값 `1000` |

### Workflow

| 키 | 범위 | 용도 |
|---|---|---|
| `workflow.max_concurrency_per_run` | 테넌트 | Workflow run 하나가 요청할 수 있는 최대 task 동시성. 기본값은 `8`, 범위는 `1`–`32` |
| `workflow.max_running_per_agent` | 테넌트 | Agent 하나의 모든 Workflow에서 동시에 실행할 수 있는 task 수. 기본값은 `8`, 범위는 `1`–`64` |
| `workflow.max_agent_calls_per_run` | 테넌트 | Workflow run 하나가 만들 수 있는 총 `agent()` 호출 수. 기본값은 `32`, 범위는 `1`–`1,024` |

Workflow 생성 요청은 이 상한을 높일 수 없습니다. 요청한 `concurrency`나 `max_agent_calls`가 더 높으면 Ankole이 테넌트 상한으로 낮추어 저장합니다. 작업 분할과 결과 확인 방법은 [Workflows](../workflows/)를 참조하세요.

### Brain

| 키 | 범위 | 용도 |
|---|---|---|
| `brain.enabled` | 테넌트 | Brain 검색, 학습, 유지 관리를 활성화합니다. 비활성화해도 저장된 지식은 유지됩니다. |
| `brain.maintainer_agent_uid` | 테넌트 | Brain 유지보수를 담당하는 활성 Agent입니다. 모든 Brain 모델 호출은 이 Agent의 ID로 실행되고 사용량도 이 Agent에 귀속됩니다. 비활성화하면 다시 활성화하거나 교체할 때까지 해당 호출과 URL Source 가져오기가 중지됩니다. Agent 페이지에서 `light`, `heavy`, `web_fetch` profile을 편집합니다. |
| `brain.embedding_model` | 사이트 | 벡터 검색에 사용할 Provider, 모델, 차원 수입니다. 비어 있으면 벡터 검색을 비활성화합니다. |
| `brain.rerank_model` | 테넌트 | 검색 결과 rerank에 사용할 Provider와 모델입니다. 비어 있으면 융합 결과 순서를 유지합니다. |
| `brain.search_tokenizer` | 사이트 | BM25 tokenizer: `icu`, `jieba`, `lindera_japanese`, `lindera_korean`. 변경 후에는 BM25 index를 다시 만들어야 합니다. |
| `brain.chunking` | 테넌트 | Source chunk 크기, overlap, 입력 상한입니다. |
| `brain.forgetting` | 테넌트 | 지식 종류별 감쇠 반감기와 soft-delete purge 간격입니다. |
| `brain.dreaming_task_cron` | 테넌트 | 정기 지식 통합 schedule입니다. |
| `brain.self_healing_task_cron` | 테넌트 | 오래된 chunk, embedding, 검색 index projection을 다시 만드는 schedule입니다. |
| `brain.signal_channel_batch_idle_time` | 테넌트 | 대기 중인 chat message가 학습에 들어가기 전까지의 idle 초입니다. 대화 종료 시에도 학습을 시작합니다. |
| `brain.skill_learning_enabled` | 테넌트 | Skill lesson 학습과 전달을 활성화합니다. 비활성화하면 저장된 lesson은 유지되지만 제공되지 않습니다. |
| `brain.skill_learning_reflection_threshold` | 테넌트 | Agent 하나가 Skill lesson reflection을 시작하기 전에 쌓아야 하는, 아직 소비되지 않은 Signal Job 수입니다. 최솟값은 `2`입니다. |

지식 동작과 모델 요구 사항은 [Brain](../brain/)을 참조하십시오. Skill과 함께 제공되는 lesson은 [Skill lessons](../skill-lessons/)를 참조하십시오.

### AI Gateway 및 observability

| 키 | 범위 | 용도 |
|---|---|---|
| `ai_gateway.compaction` | 사이트 | 대화 히스토리 자동 압축 정책 |
| `observability.traces.enabled` | 사이트 | 다음 control-plane startup에서 process-wide OpenTelemetry export를 활성화할지 여부 |
| `observability.traces.provider` | 사이트 | `langfuse`, `langsmith` 또는 범용 `opentelemetry` trace의 semantic projection |
| `observability.traces.otlp_endpoint` | 사이트 | optional trace의 base OTLP/HTTP endpoint |
| `observability.traces.otlp_headers` | 사이트 | optional trace의 암호화된 authentication header |

Langfuse, LangSmith, VictoriaTraces 및 다른 OTLP/HTTP receiver 구성은 [LLM observability](../llm-observability/)를 참조하십시오.

### 패스워드리스 Email OTP 및 Pod 로그인 정책

| 키 | 범위 | 용도 |
|---|---|---|
| `authn.email.mail` | 사이트, 암호화 | 패스워드리스 Email OTP 로그인용 SMTP 메일 전송 설정(`server`, `from`, `port`, `ssl` 및 선택적 자격 증명); 비어 있으면 Email OTP 비활성화 |
| `authn.email.code_ttl_seconds` | 사이트 | 인증 코드 유효 시간(초); 기본값 `600` |
| `authn.email.send_window_seconds` | 사이트 | Email OTP 코드 발송 속도 제한 윈도우(초); 기본값 `60` |
| `authn.email.send_email_limit` | 사이트 | 발송 윈도우당 하나의 이메일 주소로 보낼 수 있는 최대 코드 수; 기본값 `3` |
| `authn.email.send_source_limit` | 사이트 | 발송 윈도우당 하나의 출발지 주소에서 보낼 수 있는 최대 코드 수; 기본값 `20` |
| `authn.email.send_channel_limit` | 사이트 | 발송 윈도우당 채널 전체에서 보낼 수 있는 최대 코드 수; 기본값 `100` |
| `authn.email.failure_window_seconds` | 사이트 | 코드 검증 실패 속도 제한 윈도우(초); 기본값 `600` |
| `authn.email.failure_email_limit` | 사이트 | 실패 윈도우당 하나의 이메일 주소에 허용되는 최대 검증 실패 횟수; 기본값 `10` |
| `authn.email.failure_source_limit` | 사이트 | 실패 윈도우당 하나의 출발지 주소에 허용되는 최대 검증 실패 횟수; 기본값 `100` |
| `principals.pod_login_policy` | 테넌트, 다른 곳에서 관리 | Pod 구성원 로그인 및 초대 정책(`allow_email_otp`, `allow_member_credential_change`, `allowed_email_domains`, `require_sso_for_members`, `allow_invite_links`); Pod Settings에서 관리 |

### Identity, 플러그인, 기능 플래그 및 테넌트 기본값

| 키 | 범위 | 용도 |
|---|---|---|
| `principals.identity_providers.active` | 테넌트, 읽기 전용 | Pod 워크스페이스 구성원과 관리자를 인증하는 활성 테넌트 Identity Provider; Pod Settings 및 Identity Provider 페이지에서 관리 |
| `principals.identity_providers.directory_full_sync_interval_minutes` | 테넌트 | 전체 조직 디렉터리 동기화 간격 |
| `tenants.privileged_tenant_id` | 사이트, 읽기 전용 | 이 사이트를 관리하는 `siteadmin` 그룹이 속한 특권 테넌트 ID |
| `plugins.enabled_ids` | 사이트, 다른 곳에서 관리 | 다음 시작 시 활성화할 `:optional` Control Plane Plugin; `:always` 플러그인은 빌드와 함께 항상 활성 상태 유지 |
| `features.<flag>` | 사이트 | OpenFeature를 뒷받침하는 기능 가용성 정책(`{enabled, percent, targets}`, `Ankole.Features.Config`) |
| `signals.show_dead_letter_error_details` | 사이트 | Conversation에 전송되는 데드레터 알림에 길이 제한 및 마스킹된 Session 턴 오류 세부 정보를 포함할지 여부; 기본값 `false` |
| `system.timezone` | 테넌트 | 스케줄 및 기타 제어 플레인 기능의 기본 시간대 |
| `i18n.default_locale` | 테넌트 | Ankole 인터페이스의 기본 언어 |

### Workers, 웹 읽기 및 보안

| 키 | 범위 | 용도 |
|---|---|---|
| `runtime_fabric.worker_auth_key` | 사이트, 읽기 전용 | 제어 플레인이 처음 시작할 때 생성하는 설치 키; Lark profile 이름을 정하며, Worker 자격 증명이 아님 |
| `agent_computer.worker.ready_timeout` | 사이트 | Worker가 ready가 아닌 상태로 있을 수 있는 초; 넘으면 새 캐시 디스크로 다시 만듦; 기본값 `600`(10분) |
| `worker.rendered_fetch_idle_ttl_ms` | 테넌트 | 내장 `web_fetch` 렌더링 폴백의 유휴 수명 |
| `security.ssrf_filter` | 사이트 | 모델 제어 fetch가 private, loopback, link-local, CGNAT 주소를 거부할지 여부 |

이 설정이 꺼져 있어도 클라우드 메타데이터 주소는 거부됩니다.

`agent_computer.worker.ready_timeout`은 이미 관측한 준비되지 않은 인스턴스를 복구합니다. 유휴 해제는 provider YAML의 `idleReleaseAfter`로 설정합니다. [Worker](../worker-management/)를 참조하세요.

### 최초 실행 상태

| 키 | 범위 | 용도 |
|---|---|---|
| `setup.bootstrap_activation_code` | 사이트, 읽기 전용 | 최초 실행 설정 페이지용 임시 활성화 코드 |
| `setup.completed` | 사이트, 읽기 전용 | 이 인스턴스가 최초 실행 설정을 완료했는지 여부 |

최초 실행 설정 플로우가 이러한 키를 소유합니다. 활성화 코드를 읽으려면 `kit show bootstrap-activation-code`를 실행하세요. AppConfigure 페이지에서 이러한 키를 편집하지 마세요.

## 암호화된 설정

Ankole은 credential 설정을 암호화된 형태로 저장하고 목록과 편집기에 마스크를 표시합니다. 마스크를 저장하면 현재 값이 유지됩니다. 새 내용을 입력하면 대체됩니다.

**Reveal**은 현재 값을 확인해야 할 때만 사용하세요. 공개된 credential을 채팅, 스크린샷, 티켓에 복사하지 마세요.
