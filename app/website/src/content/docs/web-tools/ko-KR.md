---
title: Web 도구
description: Agent의 웹 검색과 페이지 읽기를 구성하고, 언제 브라우저 자동화를 대신 사용해야 하는지 안내합니다.
section: User guide
order: 33
---

Agent는 `web_search`로 공개 웹 페이지를 검색하고 `web_fetch`로 선택한 페이지 본문을 읽어 옵니다. `web_search`를 쓰려면 반드시 지원 Provider를 연결해야 하지만, `web_fetch`는 별도 Provider를 구성하지 않아도 Worker에 내장된 렌더링 폴백으로 동작할 수 있습니다.

## 올바른 tool 선택

| Capability | 용도 | 실행 표면 |
|---|---|---|
| `web_search` | 키워드, 기간, 출처 범위를 지정해 공개 웹 페이지 검색 | Main Agent 및 Background Agent Jobs |
| `web_fetch` | 알고 있는 하나 이상의 공개 URL 본문을 텍스트로 추출 | Main Agent 및 Background Agent Jobs |
| [브라우저 자동화](../browser-automation/) | 로그인, 클릭, 양식 입력, 페이지 이동, 스크린샷 촬영, 동적 인터랙티브 페이지 탐색 | **Background Agent Jobs 전용** |

브라우저 자동화는 `browser` Skill(`ankole-runtime: background_job`)을 통해 제공됩니다. 따라서 `web_search`나 `web_fetch` Provider 목록에는 나타나지 않으며, 일반 Main Agent 대화 턴에서 직접 실행할 수도 없습니다.

실제 브라우저 조작이 필요한 작업이라면 Main Agent에게 Background Agent Job을 생성해 처리해 달라고 요청하세요. 백그라운드 Job은 현재 대화를 가로막지 않고 돌아가며, 진행 중 확인 질문이나 상태 알림, 최종 결과만 원래 대화방으로 전달합니다.

## Web tool 구성

### Provider 추가

1. **Console → LLM Providers**를 엽니다.
2. `web_search`, `web_fetch`, 또는 두 기능을 모두 지원하는 Provider 종류를 선택합니다.
3. API 키와 해당 Provider의 필수 설정 필드를 입력합니다.
4. 저장한 뒤 Provider가 활성 상태로 표시되는지 확인합니다.

동일한 Provider 종류로 여러 인스턴스를 등록할 수도 있습니다. 예를 들어 Bright Data SERP 인스턴스를 두 개 만들어 검색 국가를 다르게 지정하거나 서로 다른 Agent에 분리해 할당할 수 있습니다.

### Agent에 Provider 할당

1. **Console → Agents**를 열고 대상 Agent를 선택합니다.
2. **Model profiles**에서 `web_search`를 찾아 검색 기능을 지원하는 Provider를 지정합니다.
3. `web_fetch`를 찾아 페이지 읽기를 지원하는 Provider를 지정합니다.
4. 두 프로필을 저장하고 새 대화를 시작합니다.

이 두 프로필은 모델 이름이나 컨텍스트 길이를 고르지 않고 Provider 인스턴스만 선택합니다. 각 Provider 종류마다 지원하는 Capability가 선언되어 있어, 드롭다운에는 해당 기능을 지원하는 인스턴스만 표시됩니다.

선택 목록이 비어 있다면 먼저 호환되는 Provider를 등록하세요. 초기 Provider 등록 절차는 [빠른 시작](../quickstart/#llm-providers)을 참조하세요.

## 현재 내장 Provider

Control Plane Plugin을 통해 추가 Provider 종류를 확장할 수 있으며, Ankole에 기본 내장된 Provider는 다음과 같습니다.

### `web_search` Provider

| Provider | `web_fetch` 겸용 여부 | 주요 특징 | 적합한 상황 |
|---|---|---|---|
| **Parallel** | 예 | 단일 Provider로 검색과 본문 추출을 모두 제공하며 목표 지정, 복수 쿼리, 검색 모드, 총 글자 수 예산을 지원 | 자격 증명 하나로 검색과 페이지 읽기를 함께 쓰거나 심층 조사형 쿼리가 많을 때 |
| **Bright Data SERP** | 아니요 | SERP API 기반으로 동작하며 Zone 지정이 필요하고 국가, 언어, Google 도메인 선택 가능 | 검색 국가·언어 및 지역화된 검색 결과를 세밀하게 제어해야 할 때 |
| **Jina Search** | 아니요 | 국가·위치·언어·페이지 번호·캐시·검색 엔진 옵션 지원 | 지역 지정, 페이지네이션, 캐시 제어가 필요한 직접 웹 검색을 원할 때 |
| **AgentBull Cloud** | 예 | 웹 검색·페이지 추출과 모델 기능(`llm`, `embedding`, `rerank`, `image_generate`)을 하나로 묶어 제공하며 출처 제한, 기간 필터, 캐시 우회 지원 | 단일 API 키로 모델과 웹 도구를 통합 관리하거나 명시적인 도메인·기간 필터가 필요할 때 |

Parallel이나 AgentBull Cloud 인스턴스는 하나만 등록해 `web_search`와 `web_fetch` 양쪽에 동시에 할당할 수 있습니다.

반면 Jina Search와 Jina Reader는 서로 별개의 Provider 종류이므로, 동일한 Jina API 키를 쓰더라도 각각 따로 등록해 해당 프로필에 연결해야 합니다.

### `web_fetch` Provider

| Provider | `web_search` 겸용 여부 | 주요 특징 | 적합한 상황 |
|---|---|---|---|
| **Parallel** | 예 | Parallel Search와 동일한 Provider 및 자격 증명으로 페이지 본문 추출 | 이미 Parallel Search를 사용 중이어서 단일 구성으로 통일하고 싶을 때 |
| **AgentBull Cloud** | 예 | 동일한 AgentBull Cloud Provider 및 API 키로 공개 페이지 본문 추출 | 모델이나 검색에서 이미 AgentBull Cloud를 쓰고 있어 단일 자격 증명으로 관리하고 싶을 때 |
| **Jina Reader** | 아니요 | 공개 웹 페이지를 Markdown으로 변환하며 링크 보존, 대상·대기 CSS selector, 캐시, 렌더링 엔진, 토큰 한도 옵션 지원 | 깔끔한 기사 본문이나 페이지 내 특정 영역만 골라 읽어야 할 때 |

`web_fetch`는 로그인이 필요 없는 공개 HTTPS 텍스트 페이지를 읽기 위한 도구이며, PDF·이미지·압축 파일·오디오·비디오 바이너리 다운로드 도구가 아닙니다.

Worker에 내장된 렌더링 폴백은 외부 Provider가 아니므로 Console의 Provider 목록에는 나타나지 않으며, 렌더링된 페이지의 텍스트만 추출해 반환합니다. 클릭이나 키 입력, 로그인 세션 유지, 스크린샷 촬영은 수행할 수 없으며 Main Agent에 브라우저 자동화 기능을 부여하지도 않습니다.

일부 Provider가 제공하는 대기(wait) 옵션이나 CSS selector 지정은 늦게 렌더링되는 텍스트를 읽는 데는 도움이 되지만, 실제 사용자 상호작용을 대신하지는 못합니다. 로그인, 버튼 클릭, 양식 제출이 필요한 페이지라면 Background Agent Job에서 브라우저 자동화를 사용하세요.

## Agent에게 Web tool 사용 요청

별도의 특수 명령어를 외울 필요 없이 원하는 결과만 자연스럽게 설명하면 됩니다.

> 이번 주의 관련 공지 세 개를 찾으세요. 원본 페이지를 읽고 변경 사항을 비교한 뒤 출처 링크를 포함하세요.

이렇게 요청하면 Agent가 먼저 검색을 수행한 뒤 읽을 가치가 있는 페이지를 골라 본문을 확인합니다. 확인할 URL을 이미 알고 있다면 링크를 바로 건네주며 내용을 읽고 요약해 달라고 요청하세요.

반면 다음과 같은 상황에서는 브라우저를 사용해 달라고 명시적으로 요청하세요.

- 페이지 열람에 로그인이 필요한 경우
- 본문을 보기에 앞서 클릭, 검색어 입력, 페이지네이션 이동 등 조작이 필요한 경우
- 실제 화면 스크린샷이나 시각적 렌더링 상태를 확인해야 하는 경우
- 복합적인 화면 조작을 거친 뒤에만 데이터가 나타나는 경우

브라우저 작업은 Background Agent Job에서 실행됩니다. 일반적인 키워드 검색, 공개 문서 열람, 다중 출처 비교 작업에는 더 빠르고 가벼운 `web_search`와 `web_fetch`를 바로 사용하세요.

## Web 작업이 동작하지 않을 때

### 검색 또는 fetch 실패

다음 항목을 순서대로 점검하세요.

1. 대상 Agent에 작업에 필요한 프로필이 연결되어 있는지 확인합니다(`web_search`는 반드시 Provider 지정이 필요합니다).
2. `web_fetch`에 별도 Provider가 지정되어 있지 않다면 Worker가 정상 기동되어 내장 렌더링 폴백을 수행할 수 있는지 확인합니다.
3. 연결한 Provider 종류가 해당 Capability를 지원하는지 확인합니다.
4. Provider가 활성 상태이고 API 키 및 필수 설정값이 유효한지 확인합니다.
5. 프로필 설정을 바꾼 뒤 새 대화를 시작했는지 확인합니다.
6. 조회하려는 주소가 로그인 없이 접근 가능한 공개 HTTPS 페이지인지 확인합니다.

### 브라우저 자동화가 실행되지 않음

대상 Agent에 `browser` Skill이 활성화되어 있는지, 그리고 Background Agent Job을 생성할 수 있는 권한과 설정이 갖춰져 있는지 확인하세요. 브라우저 자동화는 모델 프로필이 아니므로 `web_search`나 `web_fetch` 슬롯에 연결하려 하지 마세요.

이미 Background Agent Job 안에서 실행 중인데도 실패한다면 Worker 가용 상태와 해당 Job이 보고한 브라우저 세션 또는 네트워크 접근 오류를 확인하세요.
