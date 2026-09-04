---
title: Web 도구
description: Agent의 웹 검색과 페이지 읽기를 구성하고, 대신 브라우저를 사용해야 하는 상황을 알 수 있다.
section: User guide
order: 33
---

Agent는 `web_search`로 공개 페이지를 찾고 `web_fetch`로 선택한 페이지를 읽습니다. `web_search`에는 구성된 Provider가 필요하지만, `web_fetch`는 Provider가 구성되지 않았을 때도 Worker의 내장 렌더링 폴백을 사용할 수 있습니다.

## 올바른 tool 선택

| Capability | 용도 | 실행 표면 |
|---|---|---|
| `web_search` | 키워드, 시간, 출처 범위로 공개 페이지 찾기 | Main Agent 및 Background Agent Jobs |
| `web_fetch` | 알려진 공개 URL 하나 이상을 텍스트로 읽기 | Main Agent 및 Background Agent Jobs |
| [브라우저 자동화](../browser-automation/) | 로그인, 클릭, 입력, 페이지 넘김, 스크린샷 촬영, 인터랙티브 페이지 읽기 | **Background Agent Jobs만** |

브라우저 자동화는 `browser` Skill에서 제공되며 `ankole-runtime: background_job`을 선언합니다. `web_search`나 `web_fetch` Provider 목록에는 나타나지 않으며, 일반 Main Agent turn에서 직접 실행할 수 없다.

작업에 브라우저가 필요하면 Main Agent에게 Background Agent Job을 만들거나 사용하라고 요청하세요. Job은 현재 대화를 막지 않으며 필요할 때 질문, 상태, 결과를 되돌려 보냅니다.

## Web tool 구성

### Provider 추가

1. **Console → LLM Providers**를 연다.
2. `web_search`, `web_fetch`, 또는 둘 다를 지원하는 Provider 종류를 선택합니다.
3. API key와 필수 Provider 필드를 입력합니다.
4. 저장하고 Provider가 활성화되었는지 확인합니다.

한 Provider 종류의 인스턴스를 여러 개 만들 수 있다. 예를 들어 Bright Data SERP 인스턴스 두 개는 서로 다른 지역을 사용하거나 서로 다른 Agent에 제공할 수 있다.

### Agent에 Provider 할당

1. **Console → Agents**를 열고 Agent를 선택합니다.
2. **Model profiles**에서 `web_search`를 찾아 검색을 지원하는 Provider를 선택합니다.
3. `web_fetch`를 찾아 페이지 읽기를 지원하는 Provider를 선택합니다.
4. 두 프로필을 저장하고 새 대화를 시작합니다.

이 프로필은 Provider 전용입니다. 모델이나 컨텍스트 길이는 필요하지 않다. 각 Provider 종류는 자신의 Capability를 선언하므로 목록에는 일치하는 인스턴스만 들어 있다.

목록이 비어 있으면 먼저 일치하는 Provider를 추가하세요. 첫 Provider 설정은 [빠른 시작](../quickstart/#llm-providers)을 보라.

## 현재 내장 Provider

Control Plane Plugin이 Provider 종류를 더 추가할 수 있다. 현재 Ankole에 내장된 종류는 다음과 같다.

### `web_search` Provider

| Provider | `web_fetch`도 지원 | 주요 차이 | 사용 시기 |
|---|---|---|---|
| **Parallel** | 예 | Provider 하나가 검색과 추출을 모두 제공합니다. 목표, 여러 쿼리, 모드, 총 문자 예산을 지원 | 검색과 읽기에 자격 증명 하나를 쓰고 싶거나 조사 지향적인 쿼리가 있을 때 |
| **Bright Data SERP** | 아니요 | SERP API를 사용합니다. Zone이 필요하며 국가, 언어, Google 도메인을 선택할 수 있음 | 검색 지역, 언어, 지역화된 결과를 제어해야 할 때 |
| **Jina Search** | 아니요 | 지역, 위치, 언어, 페이지, 캐시, 검색 엔진 옵션을 지원 | 지역, 페이지네이션, 캐시 제어가 있는 직접 웹 검색이 필요할 때 |
| **AgentBull Cloud** | 아니요 | 검색 소스를 집계하고 출처 범위, 시간 범위, 캐시 우회를 지원 | 메타 검색 또는 명시적 출처와 시간 범위가 필요할 때 |

Parallel Provider 인스턴스 하나를 `web_search`와 `web_fetch` 둘 다에 할당할 수 있다.

Jina Search와 Jina Reader는 다른 Provider 종류입니다. 같은 Jina 자격 증명을 쓰더라도 각각 따로 추가하고 각각 일치하는 프로필에 할당하세요.

### `web_fetch` Provider

| Provider | `web_search`도 지원 | 주요 차이 | 사용 시기 |
|---|---|---|---|
| **Parallel** | 예 | Parallel Search와 같은 Provider와 자격 증명으로 페이지 텍스트를 추출 | Parallel Search를 이미 쓰고 있고 구성 하나를 원할 때 |
| **Jina Reader** | 아니요 | 공개 페이지를 Markdown으로 변환합니다. 링크 유지, 대상 및 대기 selector, 캐시, 엔진, 토큰 한도를 지원 | 기사 텍스트나 페이지의 선택된 부분이 필요할 때 |

`web_fetch`는 공개 HTTPS 페이지를 위한 것입니다. 로그인하지 않으며 PDF, 이미지, 아카이브, 오디오, 비디오용 다운로더가 아닙니다.

Worker의 내장 렌더링 폴백은 Provider가 아니므로 Console Provider 목록에 나타나지 않습니다. 렌더링된 페이지 텍스트만 읽습니다.

폴백은 클릭, 입력, 로그인 상태 재사용, 스크린샷 촬영을 할 수 없다. Main Agent에게 브라우저 자동화를 주지 않습니다.

Selector와 대기 옵션은 Provider가 지연된 페이지 텍스트를 읽는 데 도움이 될 수 있지만 실제 상호작용은 제공하지 않습니다. 작업에 로그인, 클릭, 폼 입력이 필요하면 Background Agent Job에서 브라우저 자동화를 사용하세요.

## Agent에게 Web tool 사용 요청

특별한 명령은 필요 없다. 원하는 결과를 설명하세요. 예:

> 이번 주의 관련 공지 세 개를 찾으세요. 원본 페이지를 읽고 변경 사항을 비교한 뒤 출처 링크를 포함하세요.

Agent는 먼저 검색한 다음 읽을 페이지를 고릅니다. URL을 이미 알고 있으면 Agent에게 보내고 페이지를 읽고 요약하라고 요청하세요.

다음과 같은 경우 브라우저를 명시적으로 요청하라:

- 페이지에 로그인이 필요한 경우;
- Agent가 내용을 보기 전에 클릭, 입력, 페이지 이동을 해야 하는 경우;
- 작업에 스크린샷이나 렌더링된 페이지 확인이 필요한 경우;
- 내용이 복잡한 상호작용 후에만 나타나는 경우.

브라우저 작업은 Background Agent Job에서 실행됩니다. 일반적인 검색, 공개 페이지 읽기, 다중 소스 비교에는 `web_search`와 `web_fetch`를 직접 사용하세요.

## Web 작업이 동작하지 않을 때

### 검색 또는 fetch 실패

다음 항목을 순서대로 확인하세요:

1. 현재 Agent에 작업에 필요한 프로필이 있다. `web_search`에는 Provider가 필요합니다.
2. `web_fetch`에 Provider가 없으면 Worker가 내장 렌더링 폴백을 제공합니다.
3. 선택한 Provider 종류가 필요한 Capability를 선언합니다.
4. Provider가 활성화되어 있고 자격 증명과 필수 필드가 유효합니다.
5. 프로필을 변경한 후 새 대화를 시작했습니다.
6. 대상이 로그인이 필요 없는 공개 HTTPS 페이지입니다.

### 브라우저 자동화가 실행되지 않음

Agent에 `browser` Skill이 활성화되어 있고 Background Agent Job을 만들 수 있는지 확인하세요. 브라우저 자동화를 `web_search`나 `web_fetch` 프로필에 할당하려 하지 마라.

작업이 이미 Background Agent Job에 있으면 Worker 가용성과 Job이 보고한 브라우저 세션 또는 접근 문제를 점검하세요.
