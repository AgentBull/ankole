---
title: Agent Library
description: 테넌트 및 에이전트별 Agent Plugins와 Skills, 그리고 사이트 범위의 Control Plane Plugins를 관리합니다.
section: User guide
order: 32
---

멤버는 **Meta Ankole → Skills**에서 완전한 Skill 패키지를 관리합니다. Console의 **Agent Library**에서도 기능을 켜고 끌 수 있으며, 사이트 관리자는 Site Admin Console에서 Control Plane Plugin을 관리합니다. 기본 Skill과 Agent Plugin은 Ankole에 포함되며, 권한이 있는 멤버는 사용자 정의 Skill을 만들거나 가져올 수 있습니다.

## 세 가지 능력 유형 이해하기

| 유형 | 범위 | 용도 | 변경 사항 반영 시점 |
|---|---|---|---|
| **Agent Plugin** | 테넌트 기본값 + 에이전트별 재정의 | 연관된 Skills, MCP 의존성, workspace 템플릿을 하나의 패키지로 묶어 제공 | Agent의 다음 턴 |
| **Skill** | 모든 Agent에서 활성화 또는 개별 Agent 지정 | 반복 수행하는 단일 작업 유형의 절차 지침과 보조 리소스 제공 | Agent의 다음 턴 |
| **Control Plane Plugin** | 사이트 범위 전용 (`/api/v2/site/control-plane-plugins`) | 컴파일 타임 풀스택 플랫폼 확장(서브시스템 어댑터, OTP 서비스, HTTP 플러그, 확장 라우트, 도메인 훅, 설정 필드, Web UI 슬롯) | 빌드 시 상시 활성 고정(`activation: :always`) 또는 control plane의 다음 시작(`activation: :optional`) |

### Agent Plugin: 하나의 패키지를 공유하는 능력

Ankole의 Agent Plugin은 <a href="https://developers.openai.com/plugins" target="_blank" rel="noreferrer">OpenAI Plugin</a> 규격을 확장한 상위 집합(superset)입니다.

OpenAI Plugin이 하나 이상의 Skills, MCP 서버, 선택적 UI를 한 패키지로 묶는 구조라면, Ankole은 여기에 **workspace template**을 더했습니다. 덕분에 단순 프롬프트 지침을 넘어 작업 절차, 실행 도구, 초기 작업 공간까지 한꺼번에 준비해 줄 수 있습니다.

Console에서 Agent Plugin을 켜면 포함된 패키지를 Agent가 사용할 수 있게 되며, 패키지 안의 개별 멤버 Skill도 필요에 따라 각각 켜거나 끌 수 있습니다.

#### workspace template은 복잡한 작업을 준비합니다

Agent Plugin 안에 `workspace-template/` 디렉터리가 있으면, Ankole이 새 Background Agent Job을 생성할 때 이 템플릿을 해당 Job의 워크스페이스로 복사해 초기화할 수 있습니다.

템플릿에는 `AGENTS.md`, 하위 디렉터리 구조, 조사 방법론, 검증 스크립트, Playbooks 등의 작업 파일을 미리 담아 둘 수 있으며, 생성된 Job은 이후 상태를 갱신하고 장애 시 복구할 수 있는 영속 워크스페이스를 갖게 됩니다.

대표적인 사례가 Ankole의 [Deep Research](../deep-research-job/)입니다. 메인 Agent가 먼저 대화방에서 사용자와 조사 범위·목적을 확인한 뒤, `deep-research` 워크스페이스 템플릿을 지정해 Background Agent Job을 시작합니다. 그러면 조사 워크플로와 근거 자료 디렉터리, 분석 기법, 검증 도구가 갖춰진 워크스페이스 위에서 Job이 자료 수집부터 분석 보완, 최종 보고서 작성까지 일관되게 수행합니다.

workspace template이 포함된 Agent Plugin을 활성화하더라도 진행 중인 대화가 달라지거나 Job이 저절로 만들어지지는 않습니다. 실제로 해당 템플릿을 지정해 새 Job을 생성할 때만 워크스페이스 초기화가 일어납니다.

### Skill: 반복 가능한 하나의 작업 방법

Ankole Skills는 <a href="https://agentskills.io/specification" target="_blank" rel="noreferrer">공식 Agent Skills 사양</a>을 따릅니다.

모든 Skill은 YAML frontmatter가 포함된 `SKILL.md` 파일을 최소 하나 가지며, 필요에 따라 `scripts/`, `references/`, `assets/` 디렉터리를 함께 둘 수 있습니다.

Agent는 평소 각 Skill의 이름과 요약 설명만 먼저 확인하다가, 현재 맡은 작업과 부합할 때 비로소 전체 지침과 필요한 참조 파일을 읽어 들입니다.

Skill은 특정 종류의 작업을 완수하는 절차를 정의합니다. 만약 그 과정에서 실시간 외부 데이터 조회나 인증, 통제된 쓰기 작업이 필요하면 Skill 안에서 사용할 MCP 도메인 도구를 지정해 mcporter로 호출할 수 있습니다. 이때 전체 MCP 카탈로그가 모델 앞에 별도의 도구 레지스트리로 노출되지는 않습니다.

#### Ankole 확장: Skill 실행 표면 선택

Ankole은 표준 frontmatter에 실행 표면을 지정하는 `ankole-runtime` 필드를 추가합니다.

```yaml
---
name: my-skill
description: Use for tasks that meet these conditions.
ankole-runtime: any
---
```

| 값 | 사용할 수 있는 실행 표면 | 적합한 상황 |
|---|---|---|
| `any` | 메인 Agent 및 Background Agent Jobs | 어느 실행 표면에서든 안전하게 작업을 마칠 수 있을 때(필드 생략 시 기본값) |
| `main` | 메인 Agent 대화 전용 | 사용자에게 되묻거나 선택을 확인받고, Background Agent Job을 생성·관리해야 할 때 |
| `background_job` | Background Agent Jobs 전용 | 실행 시간이 길거나 전용 Job 워크스페이스가 필요하며, 파일·브라우저·데이터 처리를 단일 Job 안에서 수행할 때 |

이 필드는 해당 Skill을 어느 실행 표면에 노출할지만 제어할 뿐, 직접 Background Agent Job을 생성하지는 않습니다.

예를 들어 Deep Research의 진입용 Skill은 원래 대화방에서 요구 사항을 확인하고 Job을 띄워야 하므로 `main`으로 선언되며, 실제 심층 조사를 수행하는 세부 Skills는 생성된 Background Agent Job 안에서 동작합니다.

#### 공유 Skill 패키지

각 Skill은 필수 `SKILL.md`와 부속 파일로 구성되며 [Meta Ankole](../agent-library/)에서 관리합니다. 활성화한 Agent는 `/drive/Skills/<slug>/`에서 패키지 전체를 읽을 수 있습니다. `skill_view`는 매니페스트를 읽고 참고 파일은 상대 경로로 명시적으로 읽습니다. Skill 지침은 Brain 지식과 별도로 관리합니다.

### Control Plane Plugin: 사이트 범위 풀스택 플랫폼 확장

Control Plane Plugin은 OpenAI Plugin이 아니며 Agent의 프롬프트 컨텍스트에 들어가지도 않고, 테넌트나 개별 Agent 단위로 나뉘어 동작하지도 않습니다. 릴리스 바이너리에 정적으로 함께 컴파일되어 기동 시 불변 `:persistent_term` 스냅샷으로 고정되는 사이트 범위 플랫폼 확장입니다.

하나의 Control Plane Plugin은 스택 전반에 걸쳐 다음과 같은 확장 지점을 제공할 수 있습니다.

- 서브시스템 어댑터(`signals.adapter`, `principals.identity_provider`, `ai_gateway.provider`, `agent_workers.provider`) 및 감독 대상 OTP 프로세스(`children/0`)
- 외곽 HTTP 엣지 `Plug` 및 범위가 분리된 확장 JSON:API 라우트
- 동기식 도메인 트랜잭션 훅 `hooks/0`(`Ankole.Plugins.Hook`)
- 선언적 `AppConfigure` 설정 필드(`ConfigFields`) 및 타입 안전 Web UI 슬롯(`entries.json`의 `overrides`)

각 Control Plane Plugin은 `activation: :optional | :always` 중 하나를 선언합니다. 선택적 플러그인(기본값 `:optional`)은 `plugins.enabled_ids` 설정으로 켜고 끄며 다음 control plane 기동 시 반영됩니다. 반면 `activation: :always`를 선언한 플러그인은 소스 빌드 시점부터 상시 활성으로 고정되어 비활성화할 수 없습니다. 재시작 없이 런타임에 즉시 전환하거나 점진적으로 배포해야 하는 기능 스위치에는 OpenFeature(`Ankole.Features`)를 사용합니다.

## Agent Plugins와 Skills 관리

### Skill 활성화

**Meta Ankole → Skills**에서 Skill을 선택합니다. 관리자는 모든 Agent에서 활성화하거나 개별 AI 동료를 지정할 수 있습니다. 각 멤버는 자신의 어시스턴트를 설정할 수 있습니다. 전체 스위치가 켜져 있으면 개별 스위치는 활성 상태로 표시되며 변경할 수 없습니다. 전체 스위치를 끄면 저장한 개별 설정이 복원됩니다. 사용자 정의 Skill은 생성 시 비활성 상태입니다.

Agent Plugin에 포함된 Skill은 상위 Plugin도 활성화해야 합니다. 변경 사항은 다음 턴부터 적용되며 기존 백그라운드 Job에는 생성 시의 기능 허용 목록이 적용됩니다.

### Agent Plugin 설정

Console의 **Agent Library**에서 **Global defaults**를 선택하여 Plugin 기본값을 설정하거나, Agent를 선택하여 **Follow global**, **Enabled**, **Disabled**를 지정합니다. 상위 Plugin을 끄면 포함된 Skill은 사용할 수 없지만 개별 설정은 유지됩니다.

### Skill 교훈 검토

Agent는 Skill 본문과 함께 날짜가 기록된 작업 주의 사항(교훈)을 함께 전달받을 수 있습니다. Dreaming이 과거 Job 실행 증거로부터 리스가 걸린 교훈을 자동 생성할 수도 있고, 운영자가 직접 수동 교훈을 등록할 수도 있으며, 어느 경우든 공유 `SKILL.md` 원본은 변경되지 않습니다.

Agent Library 상단 범위를 특정 Agent로 전환한 뒤 해당 Skill 카드를 열면 현재 활성 교훈과 폐기된 교훈, 근거가 된 증거 Job, 재검토 예정일, 폐기 사유를 확인할 수 있습니다. 여기서 새 교훈을 추가하거나 기존 교훈을 폐기할 수 있으며, 폐기한 항목은 다음 턴부터 즉시 전달 대상에서 빠집니다.

모든 Agent가 공통으로 지켜야 할 원칙을 에이전트별 교훈에 일일이 복사해 넣지 마십시오. 공통 규칙은 Skill 원본 소스에 작성해야 합니다. 증거 판정 기준, 리스 갱신, 상세 설정은 [Skill 교훈](../skill-lessons/)을 참조하십시오.

## Control Plane Plugins 관리

### 선택적 사이트 플러그인 활성화 또는 비활성화

Control Plane Plugins는 사이트 범위 전용(`/api/v2/site/control-plane-plugins`)이므로, Site Admin Console(`/site-admin-console`)에서 Agent Library 범위를 **Global defaults**로 두었을 때만 탭이 나타납니다.

1. Site Admin Console에서 **Agent Library**를 열고 범위를 **Global defaults**로 둔 상태에서 **Control Plane Plugins** 탭을 선택합니다.
2. 원하는 선택적 플러그인(`activation: :optional`)을 찾아 **Enabled next start**로 변경합니다(`activation: :always` 플러그인은 빌드 시 상시 활성으로 고정되어 비활성화 토글이 표시되지 않습니다).
3. 변경 사항을 저장하고 control plane을 재시작합니다.
4. 다시 **Control Plane Plugins** 탭을 열어 상태가 **Active now**로 바뀌었는지 확인합니다.
5. 해당 플러그인이 제공하는 Channel Provider, Identity Provider, Worker provider 또는 추가 설정을 구성합니다.

Docker Compose 재시작 명령:

```bash
docker compose restart control-plane
```

Kubernetes 재시작 명령:

```bash
kubectl -n ankole rollout restart deployment/ankole-control-plane
```

선택적 Control Plane Plugin을 끄는 변경 역시 다음 시작 시점에 적용됩니다. 설정 저장 트랜잭션 안에서 `veto_disable` 참조 검사가 수행되므로, 어느 테넌트에든 해당 플러그인이 제공하는 Worker provider 종류가 할당된 Agent Worker(일시 중지된 Worker나 삭제 진행 중인 Agent 포함)가 하나라도 남아 있으면 Worker provider 플러그인을 비활성화할 수 없습니다. 다른 유형의 플러그인도 끄기 전에 사용 중인 활성 Channel Provider나 Identity Provider가 이에 의존하고 있지 않은지 먼저 확인하십시오. 재시작 없이 즉시 반영해야 하는 동적 기능 플래그는 OpenFeature(`Ankole.Features`)를 사용합니다.

## 문제 해결

### Agent Plugins와 Skills

- **원하는 기능이 보이지 않음:** 설치된 패키지와 선택한 범위를 확인하세요. 사용자 정의 Skill은 Meta Ankole에서 만들거나 가져옵니다. 공식 패키지는 배포에 포함되어야 합니다.
- **Skill을 켰는데도 Agent가 쓰지 못함:** 상위 Agent Plugin이 꺼져 있지 않은지 확인한 뒤 새 턴을 시작해 보십시오.
- **일부 작업에서만 Skill이 보임:** `SKILL.md`의 `ankole-runtime` 값을 확인하십시오. `main` 전용 Skill은 Background Agent Job에 전달되지 않고, `background_job` 전용 Skill은 일반 메인 Agent 대화에 전달되지 않습니다.
- **일부 Agent가 Plugin 기본값을 따르지 않음:** 해당 Agent의 Plugin 재정의를 확인하세요. Skill은 전체 스위치와 개별 설정으로 활성화 여부를 결정합니다.
- **Background Agent Job에서 workspace template을 고를 수 없음:** 대상 Agent에 해당 Agent Plugin이 활성화되어 있는지, 그리고 패키지 안에 `workspace-template/` 디렉터리가 실제로 들어 있는지 확인하십시오.

### Control Plane Plugins

- **Control Plane Plugins 탭 자체가 보이지 않음:** 사이트 범위 전용 기능이므로 Site Admin Console(`/site-admin-console`)로 접속해 **Agent Library** 상단 범위를 **Global defaults**로 전환하십시오.
- **상태가 계속 Enabled next start로 남아 있음:** `plugins.enabled_ids` 저장은 완료되었으나 부팅 스냅샷이 아직 갱신되지 않은 상태이므로 control plane을 재시작해야 합니다.
- **플러그인을 비활성화할 수 없음:** 해당 플러그인이 `activation: :always`(빌드 고정 활성)로 선언되어 있거나, 어느 테넌트에 해당 Worker provider 종류를 사용하는 Agent Worker가 남아 있어 `veto_disable` 검사에서 차단된 경우입니다.
- **재시작 후 control plane이 정상 기동되지 않음:** 부팅 로그를 확인해 플러그인 설정 누락이나 외부 의존성 오류를 수정한 뒤 다시 시작하십시오.
- **플러그인을 켰는데도 Channel Provider가 나타나지 않음:** 플러그인 상태가 **Active now**인지 먼저 확인하고, 이어서 해당 Channel Provider 설정 화면을 점검하십시오.

직접 확장을 작성하는 방법은 [Skills 및 Control Plane Plugins 개발](../writing-a-skill/)을 참조하세요.
