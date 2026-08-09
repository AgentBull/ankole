---
title: Context.dev 웹 데이터
description: Context.dev API를 통해 Agent에 bot 차단에 강한 페이지 읽기, 사이트 전체 크롤링, schema 형태의 추출, 브랜드 프로필, 예약된 변경 모니터링 기능을 제공합니다.
section: Guides
order: 307
---

Ankole은 `web_search`와 `web_fetch`로 웹을 읽고, `browser` Skill로 실제 브라우저를 구동합니다. 그래도 세 가지 모두로는 처리되지 않는 작업이 남습니다. 일반적인 fetch를 거부하는 페이지, 깨끗한 Markdown으로 변환해야 하는 문서 사이트 전체, 직접 정의한 JSON 형태로 응답해야 하는 사이트, 수개월간 관찰해야 하는 경쟁사 페이지가 그 예입니다. `context-dev` Skill은 [Context.dev](https://context.dev) API를 통해 이러한 작업을 처리합니다.

이 Skill은 기본적으로 꺼져 있으며, API key를 추가하고 활성화하기 전까지 꺼진 상태로 유지됩니다. 모든 호출은 Context.dev 계정의 credit을 소비하므로 설정은 신중하게 진행됩니다.

## Agent가 이것으로 할 수 있는 일

Skill을 활성화한 후 결과를 요청하면 Agent가 tool을 선택합니다.

```text
Read every page under example.com/docs and give me the API limits in one table.

This pricing page blocks our fetch. Get its plan names and monthly prices.

Give me the logo, brand colors, and LinkedIn page for the domain in this email signature.

Watch example.com/pricing twice a day and tell me when a plan price changes.

Which NAICS code fits stripe.com?
```

지원 범위는 다섯 가지 그룹으로 나뉩니다.

- **라이브 웹 읽기.** 검색, 한 페이지를 Markdown 또는 HTML로 변환, 페이지의 이미지 목록, 도메인의 sitemap. bot 탐지 우회와 proxy 승격이 자동으로 이루어지므로 일반 fetch를 거부하는 페이지도 대개 응답합니다.
- **사이트 전체 수집.** 최대 500페이지의 동기 크롤링, 또는 기다리기에는 너무 큰 작업을 위한 최대 25,000개 URL의 비동기 batch.
- **Schema 형태의 추출.** JSON Schema를 제공하면 Agent는 다시 읽어야 하는 산문 대신 그 형태의 데이터를 돌려받습니다.
- **브랜드 및 디자인.** 도메인, 회사 이름, 업무 이메일, ticker, 카드 설명자, 또는 페이지 URL 하나에서 회사 프로필(로고, 색상, 소셜 계정, 업종, 주소, 상장 정보)을 얻습니다. 사이트의 디자인 시스템, 글꼴, 렌더링된 스크린샷, NAICS 또는 SIC 코드도 얻을 수 있습니다.
- **변경 모니터링.** 페이지, sitemap 또는 추출 결과를 주기적으로 다시 확인하고 변경 사항을 기록하는 monitor(선택적으로 webhook 포함).

## 설정

### 1. API key 받기

[context.dev](https://context.dev)에 가입하고 API key를 만듭니다. key는 `ctxt_secret_`로 시작합니다. 무료 티어에는 500 credit이 포함되어 있어 설정을 확인하고 몇 가지 작업을 시도하기에 충분합니다.

### 2. key를 environment variable로 저장

**Console → Environment variables**를 열고 변수를 만듭니다.

- **Name:** `CONTEXT_DEV_API_KEY`
- **Value:** `ctxt_secret_...` key
- **Encrypted storage:** 켜짐

Skill이 그 이름만 선언하므로 이름은 정확히 일치해야 합니다. 모든 Agent에 대해 변수를 설정하거나, 특정 Agent만 credit을 소비해야 하는 경우 **Console → Agents → 해당 Agent → Environment variables**에서 한 Agent에만 설정합니다. 범위 규칙은 [Environment variables](../worker-env/)를 참조하세요.

### 3. Skill 활성화

**Console → Agent Library**를 열고 `context-dev`를 찾아 활성화합니다. 인스턴스 전체에 적용하거나, 필요한 Agent에만 적용할 수 있습니다. 기본값 후 override 모델은 [Agent Library](../skills/)를 참조하세요.

이 Skill은 Agent의 다음 turn부터 적용됩니다. 비활성화하면 다음 turn, 다음 Background Agent Job, 다음 Automation Job 시도에서 연결이 제거됩니다.

### 4. 동작 확인

활성화된 Agent에게 잘 아는 도메인의 브랜드 프로필 같은 간단한 작업을 요청합니다. 응답에 `401`이 있으면 key가 없거나 잘못된 것입니다. 변수 이름이 정확히 `CONTEXT_DEV_API_KEY`인지, “Not set”으로 표시되지 않는지, Agent 수준 값이 전역 값을 덮어쓰지 않는지 확인하세요.

## Ankole이 연결하는 방식

Context.dev는 `https://mcp.context.dev/mcp`에서 MCP server를 제공합니다. `context-dev` Skill은 이를 [Skill-backed MCP dependency](../mcp/)로 선언하므로 연결은 활성화된 실행이 진행되는 동안에만 존재합니다. Ankole은 각 turn, Background Agent Job 실행 또는 Automation 시도마다 비공개 단회용 mcporter 설정을 작성하며, 파일에는 변수 이름만 넣습니다. key 값은 실행 환경에만 남고 설정에 들어가지 않습니다.

Context 자체 데스크톱 안내는 브라우저 OAuth 로그인을 사용하는데, headless Worker는 이를 완료할 수 없습니다. Ankole은 같은 server가 `Authorization` header를 통해 지원하는 API-key 경로를 사용하므로 대화형 로그인이 필요하지 않습니다.

이 server는 native model tool로 등록되지 않습니다. Agent는 Skill을 읽고 tool 하나를 선택하여 mcporter를 통해 호출합니다. 이 경로는 [MCP-backed Skill 사용](../using-mcp/)에서 설명합니다.

## Credit과 비용

Context.dev는 credit 단위로 청구하며 가격은 tool에 따라 다릅니다.

| 작업 | Credit |
| --- | --- |
| 페이지 하나를 Markdown 또는 HTML로 스크랩, sitemap 하나, 이미지 목록 하나, 파싱된 파일 하나 | 1 |
| 웹 검색 | 결과당 1, 최소 결과 집합은 10 |
| 크롤링 | 페이지당 1 |
| 스크린샷, 글꼴 목록 | 5 |
| 브랜드 프로필, 디자인 시스템, 구조화된 추출, NAICS, SIC | 10 |

비용을 통제하는 두 가지 습관이 있습니다. 첫째, 크롤링과 검색은 단위당 청구되므로 큰 사이트를 무제한 크롤링하는 것이 비싼 실수입니다. Skill은 Agent에게 실제로 읽을 페이지 예산을 설정하라고 지시합니다. 둘째, monitor는 존재하는 동안 모든 실행마다 credit을 소비합니다. 시간당 monitor는 일일 monitor보다 24배 많은 비용이 들며, 누군가 삭제하기 전까지는 멈추지 않습니다. monitor를 만들 때 Agent에게 monitor ID를 요청하고, 오직 한 Agent만 비용을 지출할 수 있게 하려면 **Console → Environment variables** 범위를 검토하세요.

## 제한 사항

- **Credit은 실제 돈입니다.** 열린 웹에서 활성화된 Agent에게 조사하도록 요청하는 모든 것이 이 Skill을 사용할 수 있습니다. 이것이 중요하다면 environment variable을 특정 Agent로 범위를 제한하세요.
- **Monitor와 batch는 대화보다 오래 유지됩니다.** 이들은 Ankole이 아닌 Context.dev 계정에 존재합니다. Ankole에는 이들을 나열하는 페이지가 없으며, Agent가 Skill을 통해 이들을 나열합니다.
- **결과는 신뢰할 수 없는 입력입니다.** 스크랩된 페이지는 지시가 아니라 웹 콘텐츠입니다. Ankole은 그렇게 취급하며, 전달할 때도 동일하게 취급해야 합니다.
- **Workspace 파일에는 이 Skill이 필요하지 않습니다.** Agent의 workspace에 이미 있는 PDF나 이미지는 [`pdf` 및 `ocr` Skill](../ocr/)이 로컬에서 무료로 읽습니다.

## 다음 단계

- 여전히 첫 번째 선택인 일반 검색과 fetch: [웹 tool](../web-tools/).
- 렌더링된 세션, 로그인, 클릭: [브라우저 자동화](../browser-automation/).
- 이 Skill의 기반이 되는 선언 계약: [MCP server 참조](../mcp/).