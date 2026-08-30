---
title: Agent Library
description: Agent Plugins, Skills, Control Plane Plugins를 전역으로 또는 에이전트 하나에 대해 활성화합니다.
section: User guide
order: 32
---

Agent Library는 Agent가 사용할 수 있는 작업 방법과 확장을 결정합니다. Console은 그것들을 세 가지 유형으로 구분합니다.

이것들은 이 인스턴스에 이미 설치된 신뢰할 수 있는 구성 요소입니다. Agent Library는 공개 마켓플레이스가 아닙니다. 여기서 항목을 활성화해도 인터넷에서 알 수 없는 코드를 다운로드하지 않습니다.

## 세 가지 능력 유형 이해하기

| 유형 | 용도 | 변경이 적용되는 시점 |
|---|---|---|
| **Agent Plugin** | 관련된 Skills, MCP 능력, workspace 템플릿을 묶음 | Agent의 다음 turn |
| **Skill** | 반복 가능한 한 종류의 작업을 위한 지침과 리소스 | Agent의 다음 turn |
| **Control Plane Plugin** | chat 어댑터, identity 소스, 설정, 서비스를 control plane에 추가 | control plane의 다음 시작 |

### Agent Plugin: 하나의 패키지를 공유하는 능력

Ankole Agent Plugin은 <a href="https://developers.openai.com/plugins" target="_blank" rel="noreferrer">OpenAI Plugin</a>의 상위 집합(superset)입니다.

OpenAI Plugin은 하나 이상의 Skills, MCP 서버, 선택적 UI를 하나의 패키지로 묶을 수 있습니다. Ankole은 이 구조를 유지하면서 **workspace template**을 추가합니다.

따라서 Agent Plugin은 작업 방법, 실행 도구, 작업의 초기 환경을 제공할 수 있습니다. 단순한 프롬프트 하나 이상입니다.

Console에서 Agent Plugin을 활성화하면 해당 패키지를 Agent가 사용할 수 있게 됩니다. 각 멤버 Skill은 여전히 개별적으로 활성화하거나 비활성화할 수 있습니다.

#### workspace template은 복잡한 작업을 준비합니다

`workspace-template/` 디렉터리는 Agent Plugin에 속합니다. Ankole이 Background Agent Job을 만들 때 이 템플릿을 새 Job workspace로 복사할 수 있습니다.

템플릿은 `AGENTS.md`, 디렉터리, 조사 방법, 검증 스크립트, Playbooks, 기타 작업 파일을 제공할 수 있습니다. Job은 갱신하고 복구할 수 있는 durable workspace를 받습니다.

Ankole의 최첨단 [Deep Research](../deep-research-job/)가 대표적인 예입니다. 메인 Agent는 먼저 조사 요청을 확인한 다음 `deep-research` workspace 템플릿으로 Background Agent Job을 만듭니다.

템플릿은 조사 워크플로우, 증거 디렉터리, 분석 방법, 검증 도구를 제공합니다. Job은 하나의 workspace에서 소스를 수집하고 분석을 수정하며 최종 보고서를 만들 수 있습니다.

workspace template이 있는 Agent Plugin을 활성화해도 기존 대화는 바뀌지 않으며 Job도 생성되지 않습니다. Ankole은 작업이 그 템플릿을 선택할 때만 새 Job workspace를 초기화합니다.

### Skill: 반복 가능한 하나의 작업 방법

Ankole Skills는 <a href="https://agentskills.io/specification" target="_blank" rel="noreferrer">공식 Agent Skills 사양</a>을 따릅니다.

각 Skill은 YAML frontmatter가 있는 `SKILL.md` 파일을 최소 하나 포함합니다. `scripts/`, `references/`, `assets/`도 포함할 수 있습니다.

Agent는 먼저 이름과 설명을 봅니다. 작업이 일치한 후에야 전체 지침과 필요한 리소스를 로드합니다.

Skill은 한 종류의 작업을 완료하는 방법을 설명합니다. 워크플로우에 실시간 데이터, 인증, 또는 통제된 액션이 필요하면, Skill은 MCP 도메인 도구를 선택해 mcporter를 통해 호출할 수 있습니다. MCP 카탈로그는 모델에 보이는 두 번째 도구 레지스트리가 아닙니다.

#### Ankole 확장: Skill 실행 표면 선택

Ankole은 표준 frontmatter에 `ankole-runtime`을 추가합니다.

```yaml
---
name: my-skill
description: Use for tasks that meet these conditions.
ankole-runtime: any
---
```

| 값 | Skill을 사용할 수 있는 곳 | 언제 사용하는가 |
|---|---|---|
| `any` | 메인 Agent 및 Background Agent Jobs | 두 실행 표면 모두 안전하게 작업을 완료할 수 있음. 필드가 없을 때의 기본값이기도 함 |
| `main` | 메인 Agent 대화만 | Skill이 사용자에게 묻거나, 선택을 확인하거나, Background Agent Job을 만들고 관리해야 함 |
| `background_job` | Background Agent Jobs만 | 작업이 오래 걸리거나, Job workspace에 의존하거나, 파일, 브라우저 작업, 데이터를 하나의 Job에서 처리함 |

이 필드는 Skill이 어디에 보이는지를 통제합니다. Background Agent Job을 만들지는 않습니다.

Deep Research 진입 Skill은 원래 대화에서 요청을 확인하고 Job을 만들기 때문에 `main`을 사용합니다. 그러면 조사 Skills는 Background Agent Job 안에서 실행될 수 있습니다.

#### Ankole 확장: Brain을 통해 Skill 발견하기

일부 SOP와 방법론은 현재 작업과 관련될 때만 유용하므로 모든 Prompt에 나열하면 컨텍스트를 낭비합니다. 배포되는 Skill은 `brain-recall-only: true`를 선언할 수 있습니다. 표준 Skill이라는 점과 Agent Plugin, Skill 활성화, 실행 표면, `skill_view` 규칙은 그대로 유지됩니다. 차이는 모델에 표시되는 Skill 카탈로그에 넣지 않고 Brain이 의미에 따라 발견한다는 점입니다.

Brain은 Skill의 이름, 설명, 태그를 검색합니다. 일치하면 Agent는 `skill_view`를 호출합니다. `skill_view`는 `ankole-runtime`에 따라 호환되는 실행 표면에서는 Skill을 로드하고, 그렇지 않으면 올바른 라우팅 또는 거부 결과를 반환합니다. Skill이나 부모 Agent Plugin을 비활성화하면 해당 Agent는 Brain에서 Skill을 발견하거나 로드할 수 없습니다. 이 의미 검색 경로를 사용하려면 Brain이 활성화되어 있어야 합니다. 이 모드는 필요할 때만 사용할 수 있고 모든 Prompt를 계속 차지해서는 안 되는 배포 방법론과 SOP에 적합합니다.

### Control Plane Plugin: 관리 플랫폼 확장

Control Plane Plugin은 OpenAI Plugin이 아니며 Agent의 작업 컨텍스트에도 들어가지 않습니다. Ankole 컨트롤 플레인을 확장합니다.

Control Plane Plugin은 Channel Providers, identity 소스, 시스템 설정, 감독 서비스를 제공할 수 있습니다. 이러한 구성 요소는 시작 구조를 바꾸므로, 활성화 또는 비활성화 조치는 다음 컨트롤 플레인 시작 시에만 적용됩니다.

## Agent Plugins와 Skills 관리

### 인스턴스 기본값 설정

1. Console에서 **Agent Library**를 엽니다.
2. 범위를 **Global defaults**로 설정합니다.
3. **Agent Plugins** 또는 **Skills** 아래에서 능력을 찾습니다.
4. 그 기본값을 활성화하거나 비활성화합니다.

전역 기본값은 새 Agents와 재정의가 없는 Agents에 적용됩니다. 이미 시작된 turn은 바뀌지 않습니다. Agent는 다음 turn에서 새 능력 집합을 읽습니다.

일반적이고 위험이 낮은 능력은 기본으로 활성화하고, 예외에 대해서는 좁힙니다.

소수의 역할에만 적용되거나, 특별한 자격 증명이 필요하거나, 실질적인 위험이 있는 능력은 기본적으로 비활성화하고 필요한 곳에서만 활성화하는 편이 관리하기 쉽습니다.

### 에이전트 하나 재정의

1. Agent Library 상단에서 범위를 대상 Agent로 바꿉니다.
2. Agent Plugin 또는 Skill을 찾습니다.
3. **Follow global**, **Enabled**, **Disabled** 중 하나를 선택합니다.

**Follow global**은 예외를 제거합니다. 이후 인스턴스 기본값이 바뀌면 이 Agent에도 적용됩니다. 명시적인 enabled 또는 disabled 값은 해당 Agent의 재정의로 남습니다.

Agent Plugin은 여러 Skills를 포함할 수 있습니다. 부모를 비활성화하면 그 Skills를 사용할 수 없게 되지만 각 Skill 설정을 다시 쓰지는 않습니다. 부모를 다시 활성화하면 Skills는 각자의 유효 상태로 돌아갑니다.

### Skill 교훈 검토

Agent는 전체 Skill 지침과 함께 날짜가 있는 작업상 주의 사항을 받을 수 있습니다. Dreaming은 Job 증거에서 리스가 있는 교훈을 만들고, 운영자는 사람의 교훈을 추가할 수 있습니다. 공유 `SKILL.md`는 바뀌지 않습니다.

Agent Library 범위를 대상 Agent로 바꾼 다음 Skill 카드를 찾습니다. 카드에는 활성 교훈과 폐기된 교훈, 증거 Job, 재검토 날짜, 폐기 이유가 표시됩니다. 운영자는 교훈을 추가하거나 폐기할 수 있습니다. Agent는 다음 turn부터 폐기된 교훈을 읽지 않습니다.

일반 규칙을 각 Agent의 교훈에 복사하지 마십시오. 모든 Agent에 적용할 규칙은 Skill 소스에 작성합니다. 증거 규칙, 리스, 설정은 [Skill 교훈](../skill-lessons/)을 참고하십시오.

## Control Plane Plugins 관리

### 활성화 또는 비활성화

Channel Providers, identity 소스 등 유사한 플랫폼 능력은 Control Plane Plugins에서 비롯됩니다.

1. **Control Plane Plugins** 탭을 엽니다.
2. Plugin을 찾아 **Enabled next start**로 설정합니다.
3. 저장하고 컨트롤 플레인을 다시 시작합니다.
4. Agent Library로 돌아와 **Active now**인지 확인합니다.
5. Plugin이 제공하는 Channel Provider, identity 소스 또는 설정을 구성합니다.

Docker Compose:

```bash
docker compose restart control-plane
```

Kubernetes:

```bash
kubectl -n ankole rollout restart deployment/ankole-control-plane
```

Control Plane Plugin 비활성화도 다음 시작 시 적용됩니다. 기존 Channel Provider나 identity 소스를 사용할 수 없게 만들 수 있습니다. 비활성화하기 전에 활성 구성 중 그것에 의존하는 것이 없는지 확인하십시오.

## 문제 해결

### Agent Plugins와 Skills

- **능력이 없음:** 배포 패키지에 그것이 포함되어 있는지 확인하십시오. 라이브러리는 설치된 구성 요소만 표시할 수 있습니다.
- **Skill이 활성화되었지만 Agent가 사용할 수 없음:** 부모 Agent Plugin이 비활성화되어 있는지 확인하고 새 turn을 시작하십시오.
- **Skill이 일부 작업에서만 나타남:** `ankole-runtime`을 살펴보십시오. `main` Skill은 Background Agent Job에 들어가지 않고, `background_job` Skill은 일반 메인 Agent 대화에 들어가지 않습니다.
- **일부 Agents가 전역 변경을 무시함:** 에이전트별 재정의가 있을 수 있습니다. 각 Agent 범위를 선택해 설정을 살펴보십시오.
- **Background Agent Job이 workspace template을 선택할 수 없음:** 해당 Agent에 대해 Agent Plugin이 활성화되어 있고 Plugin이 `workspace-template/`를 포함하는지 확인하십시오.

### Control Plane Plugins

- **Control Plane Plugin이 Enabled next start라고 표시함:** 설정은 저장되었지만 컨트롤 플레인이 다시 시작되지 않았습니다.
- **다시 시작 후 컨트롤 플레인이 시작되지 않음:** 시작 로그를 읽고 Plugin 구성이나 의존성을 고친 다음 다시 시작하십시오.
- **Channel Provider가 여전히 없음:** Plugin이 **Active now**인지 확인한 다음 그 Channel Provider 구성을 살펴보십시오.

두 확장 경로 모두 [Skills 및 Control Plane Plugins 개발](../writing-a-skill/)을 참고하세요.
