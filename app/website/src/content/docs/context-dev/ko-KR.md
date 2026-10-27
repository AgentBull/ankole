---
title: Context.dev 웹 데이터
description: Context.dev API를 통해 봇 차단에 강한 페이지 읽기, 사이트 전체 크롤링, 스키마 기반 추출, 브랜드 프로필 조회, 예약된 변경 모니터링 기능을 Agent에 제공합니다.
section: Guides
order: 307
---

Ankole은 기본적으로 `web_search`와 `web_fetch`로 웹을 읽고, `browser` Skill로 실제 브라우저를 구동합니다. 하지만 일반 가져오기 요청을 차단하는 페이지, 깔끔한 Markdown으로 일괄 변환해야 하는 전체 문서 사이트, 직접 정의한 JSON 구조로 데이터를 뽑아내야 하는 사이트, 수개월 동안 추적해야 하는 경쟁사 페이지처럼 이 세 가지 도구만으로는 다루기 어려운 작업도 있습니다. `context-dev` Skill은 [Context.dev](https://context.dev) API를 연결해 이러한 작업을 처리합니다.

이 Skill은 기본적으로 비활성화되어 있으며, 운영자가 API 키를 등록하고 직접 활성화하기 전까지 켜지지 않습니다. 호출할 때마다 Context.dev 계정의 크레딧이 차감되므로 명시적인 설정 절차를 거치도록 설계되어 있습니다.

## Agent가 이것으로 할 수 있는 일

Skill을 활성화한 뒤 원하는 결과만 요청하면 Agent가 알맞은 도구를 스스로 선택해 실행합니다.

```text
Read every page under example.com/docs and give me the API limits in one table.

This pricing page blocks our fetch. Get its plan names and monthly prices.

Give me the logo, brand colors, and LinkedIn page for the domain in this email signature.

Watch example.com/pricing twice a day and tell me when a plan price changes.

Which NAICS code fits stripe.com?
```

지원 기능은 크게 다섯 가지 영역으로 나뉩니다.

- **라이브 웹 읽기.** 웹 검색, 단일 페이지의 Markdown·HTML 변환, 페이지 내 이미지 목록 조회, 도메인 사이트맵 조회를 지원합니다. 봇 탐지 우회와 프록시 단계 상향이 자동으로 처리되므로 일반 가져오기 요청을 거부하는 페이지도 대부분 읽어 올 수 있습니다.
- **사이트 전체 수집.** 최대 500페이지 규모의 동기식 크롤링은 물론, 즉시 대기하기 어려운 대규모 작업을 위해 최대 25,000개 URL 규모의 비동기 배치 수집을 지원합니다.
- **스키마 기반 추출.** JSON Schema를 전달하면 긴 본문을 다시 파싱할 필요 없이 해당 스키마에 맞춘 구조화된 데이터를 바로 돌려받습니다.
- **브랜드 및 디자인.** 도메인, 회사명, 업무용 이메일, 종목 코드(ticker), 카드 명세표 문구, 또는 페이지 URL 하나만으로도 회사 프로필(로고, 색상, 소셜 계정, 업종, 주소, 상장 정보)을 조회할 수 있습니다. 사이트의 디자인 시스템, 글꼴, 렌더링된 스크린샷, NAICS 및 SIC 산업 분류 코드도 함께 가져올 수 있습니다.
- **변경 모니터링.** 페이지, 사이트맵 또는 추출 결과를 주기적으로 다시 확인해 변경 내역을 기록하는 모니터를 생성하며, 필요하면 웹훅 알림도 연결할 수 있습니다.

## 설정

### 1. API key 받기

[context.dev](https://context.dev)에 가입해 API 키를 발급받습니다. 키는 `ctxt_secret_`으로 시작하며, 무료 티어에서 기본 제공되는 500 크레딧만으로도 설정을 검증하고 몇 가지 작업을 시험해 보기에 충분합니다.

### 2. key를 environment variable로 저장

**Console → Environment variables**를 열고 변수를 만듭니다.

- **Name:** `CONTEXT_DEV_API_KEY`
- **Value:** `ctxt_secret_...` key
- **Encrypted storage:** 켜짐

Skill이 이 변수 이름만 참조하도록 선언되어 있으므로 이름이 정확히 일치해야 합니다. 테넌트 또는 사이트 범위에서 변수를 설정할 수 있으며, 특정 Agent만 크레딧을 사용하도록 제한하려면 **Console → Agents → 해당 Agent → Environment variables**에서 개별 Agent에만 등록하세요. 자세한 범위 규칙은 [Environment variables](../worker-env/)를 참조하세요.

### 3. Skill 활성화

**Console → Agent Library**에서 `context-dev`를 찾아 활성화합니다. 테넌트 전체에 기본 적용하거나 필요한 Agent에만 개별 적용할 수 있습니다. 기본값과 개별 재정의 방식은 [Agent Library](../skills/)를 참조하세요.

활성화한 Skill은 Agent의 다음 턴부터 적용됩니다. 반대로 비활성화하면 다음 턴, 다음 Background Agent Job, 다음 Automation Job 실행 시도부터 연결이 해제됩니다.

### 4. 동작 확인

Skill을 활성화한 Agent에게 익숙한 도메인의 브랜드 프로필 조회처럼 간단한 작업을 요청해 봅니다. 응답에 `401`이 반환되면 키가 누락되었거나 잘못된 것입니다. 변수 이름이 정확히 `CONTEXT_DEV_API_KEY`인지, 상태가 “Not set”으로 표시되어 있지 않은지, 그리고 Agent별 설정이나 테넌트 재정의 값이 상위 테넌트·사이트의 `WorkerEnv` 값을 덮어쓰고 있지 않은지 확인하세요.

## Ankole이 연결하는 방식

Context.dev는 `https://mcp.context.dev/mcp`에서 MCP 서버를 호스팅합니다. `context-dev` Skill은 이 서버를 [Skill-backed MCP dependency](../mcp/)로 선언하므로, 해당 Skill이 활성화된 실행이 진행되는 동안에만 연결이 유지됩니다. Ankole은 매 턴, Background Agent Job 실행, 또는 Automation 시도마다 일회용 비공개 mcporter 설정 파일을 생성하며, 파일 안에는 변수 이름만 기록합니다. 실제 API 키 값은 실행 환경에만 머물고 설정 파일에는 기록되지 않습니다.

Context.dev 자체 데스크톱 가이드는 브라우저 기반 OAuth 로그인을 안내하지만, 헤드리스 환경에서 동작하는 Worker에서는 이 절차를 수행할 수 없습니다. 대신 Ankole은 동일한 서버가 `Authorization` 헤더로 지원하는 API 키 인증 경로를 사용하므로 별도의 대화형 로그인이 필요하지 않습니다.

이 서버는 모델의 네이티브 도구로 직접 등록되지 않습니다. 대신 Agent가 Skill 지침을 읽고 필요한 도구를 골라 mcporter를 통해 호출합니다. 자세한 호출 경로는 [MCP-backed Skill 사용](../using-mcp/)에서 설명합니다.

## Credit과 비용

Context.dev는 크레딧 단위로 과금하며 도구마다 차감량이 다릅니다.

| 작업 | Credit |
| --- | --- |
| 페이지 하나를 Markdown 또는 HTML로 스크랩, sitemap 하나, 이미지 목록 하나, 파싱된 파일 하나 | 1 |
| 웹 검색 | 결과당 1, 최소 결과 집합은 10 |
| 크롤링 | 페이지당 1 |
| 스크린샷, 글꼴 목록 | 5 |
| 브랜드 프로필, 디자인 시스템, 구조화된 추출, NAICS, SIC | 10 |

비용을 관리할 때는 두 가지 원칙을 기억해 두면 좋습니다. 첫째, 크롤링과 검색은 건당 과금되므로 대규모 사이트를 제한 없이 크롤링하면 큰 비용이 발생합니다. 이 때문에 Skill 지침에서는 실제로 읽을 페이지 수만큼만 수집 예산을 잡도록 Agent를 안내합니다. 둘째, 모니터는 삭제하기 전까지 실행될 때마다 크레딧을 소비합니다. 예를 들어 매시간 실행되는 모니터는 일일 모니터보다 24배 많은 비용이 들며, 직접 삭제할 때까지 계속 실행됩니다. 모니터를 생성할 때는 나중에 관리할 수 있도록 Agent에게 모니터 ID를 함께 알려 달라고 요청하고, 특정 Agent만 크레딧을 쓰도록 제한하려면 **Console → Environment variables**에서 변수 범위를 조정하세요.

## 제한 사항

- **크레딧은 곧 실제 비용입니다.** 이 Skill이 활성화된 Agent에게 공개 웹 조사를 요청하면 크레딧이 소진될 수 있습니다. 비용 통제가 중요하다면 환경 변수 범위를 특정 Agent로 제한하세요.
- **모니터와 배치 작업은 대화가 끝난 뒤에도 유지됩니다.** 이 리소스들은 Ankole이 아니라 Context.dev 계정에 저장됩니다. Ankole 콘솔에는 별도의 목록 화면이 없으므로, 현황을 확인하거나 정리할 때는 Agent에게 Skill을 통해 조회해 달라고 요청하세요.
- **수집 결과는 신뢰할 수 없는 외부 입력입니다.** 스크래핑한 페이지는 지시문이 아니라 외부 웹 콘텐츠일 뿐입니다. Ankole은 이를 신뢰할 수 없는 데이터로 취급하며, 결과를 다른 곳에 전달할 때도 같은 기준으로 다루어야 합니다.
- **워크스페이스 내부 파일에는 이 Skill이 필요하지 않습니다.** Agent 워크스페이스에 이미 올라와 있는 PDF나 이미지는 [`pdf` 및 `ocr` Skill](../ocr/)로 로컬에서 추가 비용 없이 읽을 수 있습니다.

## 다음 단계

- 기본 선택지로 먼저 활용하는 일반 검색 및 페이지 가져오기: [웹 tool](../web-tools/).
- 화면 렌더링, 로그인, 클릭 조작이 필요한 세션: [브라우저 자동화](../browser-automation/).
- 이 Skill의 기반이 되는 선언 계약: [MCP server 참조](../mcp/).