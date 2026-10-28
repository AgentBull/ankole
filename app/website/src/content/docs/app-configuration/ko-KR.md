---
title: AppConfigure
description: Console에서 Ankole AppConfigure 런타임 설정을 관리하고 내장 키를 참조합니다.
section: User guide
order: 43
---

**Console → AppConfigure**에서는 대화 히스토리 압축 기준, Agent 실행 한도, 디렉터리 동기화 주기, 플러그인 스위치처럼 서비스 운영 중에 관리자가 실시간으로 조정할 수 있는 런타임 설정을 관리합니다.

LLM 제공자, Identity Provider, 채팅 채널, 환경 변수는 각각 전용 Console 페이지에서 관리하므로 AppConfigure에서 설정하지 않습니다.

## AppConfigure와 환경 변수

AppConfigure 설정은 PostgreSQL에 영구 저장되어 실행 중인 Ankole 인스턴스의 제품 동작을 제어합니다. 대부분의 항목은 저장 즉시 이후 작업부터 반영되므로 재배포할 필요가 없습니다.

반면 [배포 환경 변수](../environment-variables/)는 컨트롤 플레인과 PostgreSQL 연결을 부트스트랩하고 Worker 백엔드를 초기화하는 데 사용됩니다. 배포 환경 변수를 변경한 뒤에는 영향을 받는 프로세스를 재시작해야 적용됩니다.

Skill, 명령줄 도구, 또는 MCP 서비스에 전달할 외부 API 키 같은 사용자 지정 값은 [Agent 환경 변수](../worker-env/)에 등록하세요.

## 설정 찾기

AppConfigure 페이지는 연관된 설정을 기능 그룹별로 묶어 보여 줍니다. 키 이름이나 설명으로 바로 검색하거나 그룹을 펼쳐 관련 항목들을 한눈에 확인할 수 있습니다.

각 설정 행은 다음 세 가지 상태 중 하나로 표시됩니다.

- **편집 가능(Editable):** 행을 클릭해 이 화면에서 값을 바로 수정할 수 있습니다.
- **읽기 전용(Read-only):** 현재 적용된 상태만 조회할 수 있으며 이 화면에서 직접 수정할 수 없습니다.
- **다른 곳에서 관리(Managed elsewhere):** 안내 링크를 따라가면 해당 설정을 담당하는 전용 Console 페이지로 이동합니다.

키(Key)는 코드에서 참조하는 고정 식별자이며, 설명란에는 해당 키가 제어하는 동작과 숫자 값의 단위가 안내됩니다.

## 범위와 출처 이해하기

모든 설정 키는 **사이트**, **테넌트**, 또는 **Pod** 범위를 가집니다. 사이트 키는 전체 공유 인프라 동작을 제어하고, 테넌트 키는 사이트 기본값을 상속하면서 현재 선택된 테넌트의 동작을 제어하며, Pod 키는 사이트 기본값 없이 각 Pod 워크스페이스에만 귀속됩니다. Console에서는 사이트 기본값과 테넌트별 재정의(override)를 구분해 표시하며, 개별 Agent 단위의 재정의는 지원하지 않습니다.

사이트 범위 키는 저장된 재정의 값이 있으면 그 값을 쓰고, 없으면 현재 버전의 기본값을 적용합니다. 테넌트 범위 키는 테넌트 재정의 값 → 동일 키의 사이트 기본값 → 현재 버전의 기본값 순서로 해석되며, Pod 범위 키는 워크스페이스 저장 값 → 현재 버전의 기본값 순서로 바로 해석됩니다. **Reset to default**를 누르면 선택한 범위에 저장된 재정의가 제거되며, 목록의 Source 열에서 현재 적용된 값의 출처를 확인할 수 있습니다.

## 설정 변경

1. 변경할 설정 행이나 설정 그룹을 엽니다.
2. 필드 설명을 읽어 적용 범위와 입력 단위를 확인합니다.
3. 원하는 값으로 수정한 뒤 저장합니다.
4. 목록 화면으로 돌아와 해당 행에 재정의(override) 표시가 나타나는지 확인합니다.

일반적인 설정은 전용 입력 폼을 제공하며, 복합 구조를 가진 일부 고급 설정은 JSON 편집기를 사용합니다. JSON을 편집할 때는 기존 필드 구조를 유지하고 역할을 정확히 모르는 필드는 임의로 삭제하지 마세요.

대부분의 변경 사항은 저장 직후 새로 시작되는 작업부터 적용됩니다. 만약 화면에 다음 시작 시 반영된다는 안내가 표시되면 점검 시점에 맞춰 컨트롤 플레인을 재시작하세요.

## 설정 초기화

지정해 둔 사용자 지정 값을 거두고 원래 기본값으로 되돌리려면 해당 설정을 열고 **Reset to default**를 선택하세요. 저장된 재정의가 삭제되면서 현재 설치된 Ankole 버전에 선언된 기본값이 다시 적용됩니다.

설정을 초기화하는 것과 현재 기본값 숫자를 직접 입력해 저장하는 것은 이후 업그레이드 시 다르게 동작합니다. 초기화 상태로 두면 새 버전에서 기본값이 조정될 때 변경된 기본값을 자동으로 따르지만, 값을 직접 입력해 저장해 두면 업그레이드 후에도 입력한 값이 그대로 고정됩니다.

## 현재 내장 AppConfigure 키

아래 표는 Ankole에 기본 내장된 AppConfigure 키 목록입니다. 설치된 Control Plane Plugin에 따라 추가 키가 등록될 수 있으므로, 실제 운영 인스턴스에서는 **AppConfigure** 화면에 표시되는 목록을 최종 기준으로 삼으세요.

### Agent 런타임

| 키 | 범위 | 용도 |
|---|---|---|
| `ai_agent.max_iterations` | 테넌트 | Agent 단일 턴에서 허용하는 최대 모델 추론 반복 횟수 |
| `ai_agent.max_output_tokens` | 테넌트 | 단일 모델 응답의 최대 출력 토큰 수 |
| `ai_agent.inactivity_timeout_ms` | 테넌트 | 응답이 없는 모델이나 제공자를 기다린 뒤 턴을 종료하기까지의 제한 시간(밀리초) |
| `ai_agent.library.agent_plugin_defaults` | 테넌트 | Agent Plugin의 기본 활성화 상태 |
| `ai_agent.library.skill_defaults` | 테넌트 | Skill의 기본 활성화 상태 |
| `agent_computer.background_agent_job.max_running_per_agent` | 테넌트 | Agent당 동시 실행 가능한 최대 BackgroundAgentJob 수(기본값 `3`, 유효 범위 `1`–`64`) |
| `automation_jobs.max_running_per_agent` | 테넌트 | Agent당 동시 실행 가능한 최대 자동화 스크립트 수(기본값 `10`, 유효 범위 `1`–`64`) |

### Pod, Base 및 Applet

| 키 | 범위 | 용도 |
|---|---|---|
| `pod.allow_external_guests` | 테넌트 | 초대받은 외부 게스트가 공유된 Pod 페이지에 접근하도록 허용할지 여부(기본값 `true`) |
| `pod.applet.limits` | 테넌트 | Applet 실행 한도(기본값 `timeout_ms: 60000`, `heap_mb: 128`) |
| `pod.base.limits` | 테넌트 | Base 쿼리 및 레코드 한도(기본값 `query_rows: 1000`, `record_bytes: 1000000`, `group_count: 1000`, `statement_timeout_ms: 5000`) |
| `pod.trash_retention_days` | 테넌트 | 휴지통으로 이동한 페이지를 영구 삭제하기 전까지 보관하는 일수(양의 정수, 기본값 `30`) 또는 자동 삭제 없이 무기한 보관하는 `"unlimited"` |
| `pod.ot_replay_window` | 테넌트 | OT 재생을 위해 보관하는 최근 문서 변경 배치 수(기본값 `1000`) |

### Workflow

| 키 | 범위 | 용도 |
|---|---|---|
| `workflow.max_concurrency_per_run` | 테넌트 | 단일 Workflow 실행(run)에서 요청할 수 있는 최대 동시 태스크 수(기본값 `8`, 범위 `1`–`32`) |
| `workflow.max_running_per_agent` | 테넌트 | 한 Agent의 전체 Workflow에 걸쳐 동시에 실행할 수 있는 최대 태스크 수(기본값 `8`, 범위 `1`–`64`) |
| `workflow.max_agent_calls_per_run` | 테넌트 | 단일 Workflow 실행에서 허용되는 총 `agent()` 호출 횟수(기본값 `32`, 범위 `1`–`1,024`) |

Workflow 생성 시 이 설정보다 높은 값을 요청할 수는 없습니다. 요청된 `concurrency`나 `max_agent_calls`가 테넌트 상한을 초과하면 Ankole이 자동으로 테넌트 상한 값으로 낮추어 저장합니다. 작업 분할 방식과 실행 결과 확인은 [Workflows](../workflows/)를 참조하세요.

### Brain

| 키 | 범위 | 용도 |
|---|---|---|
| `brain.enabled` | 테넌트 | Brain 검색, 학습, 유지 관리를 활성화합니다. 비활성화하더라도 이미 저장된 지식은 보존됩니다. |
| `brain.maintainer_agent_uid` | 테넌트 | Brain 유지 관리를 전담하는 활성 Agent입니다. 모든 Brain 모델 호출은 이 Agent 명의로 실행되며 토큰 사용량도 이 Agent에 귀속됩니다. 해당 Agent가 비활성화되면 다시 켜거나 다른 활성 Agent로 교체할 때까지 Brain 모델 호출과 URL Source 수집이 중단됩니다. 사용할 `light`, `heavy`, `web_fetch` 프로필은 해당 Agent 상세 페이지에서 설정합니다. |
| `brain.embedding_model` | 사이트 | 벡터 검색에 사용할 Provider, 모델, 벡터 차원 수입니다. 비워 두면 벡터 검색이 비활성화됩니다. |
| `brain.rerank_model` | 테넌트 | 검색 결과 재정렬(rerank)에 사용할 Provider와 모델입니다. 비워 두면 하이브리드 융합 순서를 그대로 유지합니다. |
| `brain.search_tokenizer` | 사이트 | BM25 검색 토크나이저(`icu`, `jieba`, `lindera_japanese`, `lindera_korean`). 값을 변경한 뒤에는 BM25 인덱스를 재구축해야 합니다. |
| `brain.chunking` | 테넌트 | Source 문서의 청크 크기, 중첩 길이(overlap), 최대 입력 크기 상한입니다. |
| `brain.forgetting` | 테넌트 | 지식 유형별 중요도 감쇠 반감기와 소프트 삭제 항목의 영구 정리(purge) 주기입니다. |
| `brain.dreaming_task_cron` | 테넌트 | 정기 지식 통합(Dreaming) 작업의 실행 스케줄입니다. |
| `brain.self_healing_task_cron` | 테넌트 | 오래된 청크, 임베딩, 검색 인덱스 투영을 재구축하는 자가 복구 스케줄입니다. |
| `brain.signal_channel_batch_idle_time` | 테넌트 | 대화방의 대기 메시지가 학습 배치로 넘어가기까지의 유휴 대기 시간(초)입니다. 대화가 종료될 때도 즉시 학습이 시작됩니다. |
| `brain.skill_learning_enabled` | 테넌트 | Skill 교훈(lesson) 학습 및 주입 기능을 활성화합니다. 비활성화하면 기존 교훈은 보존되지만 실행 시 제공되지 않습니다. |
| `brain.skill_learning_reflection_threshold` | 테넌트 | 단일 Agent에서 Skill 교훈 회고(reflection)를 시작하기 위해 누적되어야 하는 미소비 Signal Job 수입니다(최솟값 `2`). |

지식 저장·회상 방식과 모델 요구 사항은 [Brain](../brain/)을, Skill 실행 시 함께 주입되는 교훈은 [Skill lessons](../skill-lessons/)를 참조하세요.

### AI Gateway 및 observability

| 키 | 범위 | 용도 |
|---|---|---|
| `ai_gateway.compaction` | 사이트 | 대화 히스토리 자동 압축 정책 |
| `observability.traces.enabled` | 사이트 | 다음 컨트롤 플레인 시작 시 프로세스 전체 OpenTelemetry 내보내기를 켤지 여부 |
| `observability.traces.provider` | 사이트 | `langfuse`, `langsmith` 또는 일반 `opentelemetry` 트레이스용 시맨틱 매핑 방식 |
| `observability.traces.otlp_endpoint` | 사이트 | 선택적 트레이스 전송을 위한 기본 OTLP/HTTP 엔드포인트 |
| `observability.traces.otlp_headers` | 사이트 | 선택적 트레이스 전송에 사용할 암호화된 인증 헤더 |

Langfuse, LangSmith, VictoriaTraces 및 기타 OTLP/HTTP 수집기 연동 방법은 [LLM observability](../llm-observability/)를 참조하세요.

### 패스워드리스 Email OTP 및 Pod 로그인 정책

| 키 | 범위 | 용도 |
|---|---|---|
| `authn.email.mail` | 사이트, 암호화 | 패스워드리스 Email OTP 로그인용 SMTP 발송 설정(`server`, `from`, `port`, `ssl` 및 선택적 자격 증명). 비워 두면 Email OTP 로그인이 비활성화됨 |
| `authn.email.code_ttl_seconds` | 사이트 | 이메일 인증 코드 유효 시간(초, 기본값 `600`) |
| `authn.email.send_window_seconds` | 사이트 | Email OTP 발송 속도 제한 윈도우(초, 기본값 `60`) |
| `authn.email.send_email_limit` | 사이트 | 발송 윈도우당 단일 이메일 주소로 보낼 수 있는 최대 코드 수(기본값 `3`) |
| `authn.email.send_source_limit` | 사이트 | 발송 윈도우당 단일 출발지 IP에서 요청할 수 있는 최대 코드 수(기본값 `20`) |
| `authn.email.send_channel_limit` | 사이트 | 발송 윈도우당 전체 채널에서 발송할 수 있는 최대 코드 수(기본값 `100`) |
| `authn.email.failure_window_seconds` | 사이트 | 인증 코드 검증 실패 속도 제한 윈도우(초, 기본값 `600`) |
| `authn.email.failure_email_limit` | 사이트 | 실패 윈도우당 단일 이메일 주소에 허용되는 최대 검증 실패 횟수(기본값 `10`) |
| `authn.email.failure_source_limit` | 사이트 | 실패 윈도우당 단일 출발지 IP에 허용되는 최대 검증 실패 횟수(기본값 `100`) |
| `principals.pod_login_policy` | 테넌트, 다른 곳에서 관리 | Pod 구성원 로그인 및 초대 정책(`allow_email_otp`, `allow_member_credential_change`, `allowed_email_domains`, `require_sso_for_members`, `allow_invite_links`). Pod Settings에서 관리 |

### Identity, 플러그인, 기능 플래그 및 테넌트 기본값

| 키 | 범위 | 용도 |
|---|---|---|
| `principals.identity_providers.active` | 테넌트, 읽기 전용 | Pod 워크스페이스 구성원과 관리자를 인증하는 활성 테넌트 Identity Provider(Pod Settings 및 Identity Provider 페이지에서 관리) |
| `principals.identity_providers.directory_full_sync_interval_minutes` | 테넌트 | 조직 디렉터리 전체 동기화 주기(분) |
| `tenants.privileged_tenant_id` | 사이트, 읽기 전용 | 사이트 관리 권한을 가진 `siteadmin` 그룹이 소속된 특권 테넌트 ID |
| `plugins.enabled_ids` | 사이트, 다른 곳에서 관리 | 다음 시작 시 활성화할 `:optional` Control Plane Plugin 목록(`:always` 플러그인은 빌드 시 포함되며 상시 활성 유지) |
| `features.<flag>` | 사이트 | OpenFeature 기반 기능 플래그 배포 정책(`{enabled, percent, targets}`, `Ankole.Features.Config`) |
| `signals.show_dead_letter_error_details` | 사이트 | Conversation에 전송되는 데드레터 안내 메시지에 길이 제한 및 마스킹 처리된 Session 턴 오류 요약을 포함할지 여부(기본값 `false`) |
| `system.timezone` | 테넌트 | 스케줄러 및 각종 컨트롤 플레인 기능에 적용할 기본 시간대 |
| `i18n.default_locale` | Pod | 해당 Pod 워크스페이스의 인터페이스, 알림 메일, Agent 메시지 기본 표시 언어(Pod 관리자는 Pod Settings에서도 변경 가능) |

### Workers, 웹 읽기 및 보안

| 키 | 범위 | 용도 |
|---|---|---|
| `runtime_fabric.worker_auth_key` | 사이트, 읽기 전용 | 컨트롤 플레인 최초 기동 시 생성되는 설치 식별 키로 Lark 프로필 이름 등에 쓰이며 개별 Worker 자격 증명은 아님 |
| `agent_computer.worker.ready_timeout` | 사이트 | 시작된 Worker가 `ready` 상태에 도달할 때까지 기다리는 최대 시간(초, 기본값 `600`). 초과 시 새 캐시 디스크로 인스턴스를 재생성함 |
| `worker.rendered_fetch_idle_ttl_ms` | 테넌트 | 내장 `web_fetch` 브라우저 렌더링 폴백 인스턴스의 유휴 유지 시간(밀리초) |
| `security.ssrf_filter` | 사이트 | 모델이 호출하는 URL fetch 요청에서 사설망(private), 루프백(loopback), 링크 로컬(link-local), CGNAT 대역 접근을 차단할지 여부 |

참고로 `security.ssrf_filter`를 끄더라도 클라우드 인스턴스 메타데이터 주소 접근은 항상 차단됩니다.

`agent_computer.worker.ready_timeout`은 기동이 지연되어 준비 완료 상태에 이르지 못한 비정상 인스턴스를 복구하기 위한 설정이며, 정상 유휴 인스턴스의 자동 회수는 provider YAML의 `idleReleaseAfter` 항목으로 제어합니다. 자세한 내용은 [Worker](../worker-management/)를 참조하세요.

### 최초 실행 상태

| 키 | 범위 | 용도 |
|---|---|---|
| `setup.bootstrap_activation_code` | 사이트, 읽기 전용 | 최초 실행 설정 화면에서 요구하는 일회성 임시 활성화 코드 |
| `setup.completed` | 사이트, 읽기 전용 | 인스턴스의 최초 실행 설정 완료 여부 |

이 두 키는 최초 실행 설정 절차에서 자동으로 관리됩니다. 초기 활성화 코드를 확인해야 할 때는 `kit show bootstrap-activation-code` 명령을 실행하고, AppConfigure 화면에서는 직접 수정하지 마세요.

## 암호화된 설정

Ankole은 자격 증명 성격의 설정값을 암호화해 저장하며 목록과 편집 화면에는 마스킹된 형태로만 표시합니다. 마스킹된 상태 그대로 저장하면 기존 값이 유지되고, 새 값을 입력해 저장할 때만 교체됩니다.

현재 저장된 원문을 꼭 확인해야 할 때만 **Reveal** 기능을 사용하고, 화면에 표시된 자격 증명을 채팅방이나 스크린샷, 이슈 티켓에 붙여 넣지 마세요.
