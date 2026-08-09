---
title: 브라우저 자동화
description: Ankole 에이전트가 실제 브라우저 세션을 구동하는 방식 — browser Skill, web_search/web_fetch 대신 사용해야 하는 상황, 활성화 방법, 그리고 에이전트가 사전 구성된 ankole-browser CLI를 반드시 사용하고 Chromium을 직접 실행하면 안 되는 이유.
section: Guides
order: 305
---

browser Skill은 에이전트가 실제 브라우저 작업을 수행할 수 있게 해줍니다 — 페이지 열기, 클릭, 입력, 렌더링된 상태 읽기, 스크린샷 촬영, 그리고 라이브 세션에 대한 재현 가능한 Playwright 스크립트 실행. 이 Skill은 [Skill](../agent-library/)이며 내장 tool이 아니고, [백그라운드 Job](../background-jobs/)으로 실행됩니다. 이 페이지는 운영자 관점입니다: 이 Skill이 무엇인지, 언제 켜야 하는지, 에이전트가 브라우저로 무엇을 할 수 있고 무엇을 할 수 없는지.

핵심 속성을 먼저 명시합니다: 에이전트 세션당 브라우저 소유자는 하나뿐이며, 그 소유자는 에이전트가 아니라 runtime이다. 에이전트는 워커 이미지가 주입하는 사전 구성된 `ankole-browser` CLI를 통해 브라우저를 구동합니다. Chromium을 직접 실행하거나 `chromium.connectOverCDP`를 호출하면 안 된다 — 그러면 두 번째 소유자가 생기고 세션 복구를 우회하기 때문입니다.

## 브라우저 자동화란 무엇인가

Ankole에서 브라우저 자동화는 `app/library/skills/browser/SKILL.md`에 포함된 `browser` Skill이다. 백그라운드 Job runtime(`ankole-runtime: background_job`)용으로 태그된 내장 Skill(`default_enabled: true`)이다. 에이전트가 이 Skill을 호출하면 작업은 소유 turn과 격리된 백그라운드 Job 안에서, runtime이 소유하는 실제 Chromium 세션을 대상으로 실행됩니다.

Skill 자체의 description이 모델이 사용 여부를 결정할 때 읽는 계약입니다: 작업이 렌더링된 페이지 상태, 상호작용, 스크린샷, 영구 로그인 상태, 또는 재현 가능한 Playwright 워크플로에 의존하면 브라우저를 사용하고, 일반적인 발견과 텍스트 추출에는 [web_search](../web-tools/)나 [web_fetch](../web-tools/)를 우선합니다.

## 브라우저를 사용해야 하는 경우

브라우저는 무거운 경로입니다. fetch만으로 부족할 때만 사용하세요. 구체적으로:

- **렌더링된 상호작용** — JavaScript가 실행된 다음에, 또는 클릭, 스크롤, 필드 입력 후에만 페이지가 필요한 데이터를 보여주는 경우.
- **영구 로그인 상태** — runtime이 이미 인증한 세션이 필요하고, 단순한 fetch로는 로그인을 재현할 수 없는 경우.
- **스크린샷** — 작업에 시각적 산출물이 필요하거나, 사람이 페이지 상태를 확인해야 하는 경우.
- **재현 가능한 Playwright 워크플로** — 같은 다단계 브라우저 루틴을 두 번 이상 실행해야 하는 경우.

페이지를 찾거나 텍스트만 읽으려면 `web_search`나 `web_fetch`를 대신 사용하세요. browser Skill 자신도 그렇게 말한다: 이 tool들은 이 Skill밖에 있으며, 렌더링된 상호작용, 로그인 상태, 스크린샷, 브라우저 측 코드가 필요 없을 때는 그것들을 우선해야 한다. fetch는 더 저렴하고 빠르며 브라우저 세션을 소비하지 않습니다.

## 활성화 방법

브라우저는 Skill이므로 tool 플래그가 아니라 [Agent Library](../agent-library/)를 통해 켠다. `default_enabled`가 `true`이므로 축소하지 않는 한 새 Agent에는 브라우저가 이미 사용 가능합니다. 두 계층:

1. **인스턴스 전체 기본값** — Skill은 `default_enabled: true`로 제공됩니다. 그대로 두면 모든 Agent가 브라우저를 사용할 수 있다.
2. **Agent별 재정의** — 브라우저를 가지면 안 되는 Agent는 축소하고, 이전에 축소한 Agent는 확대합니다.

두 계층 모두 [Console API 참조](../console-api/)에서 다루는 Console의 library-capability 라우트로 설정합니다. Agent의 `library-capabilities`를 읽으면 Skill 동기화가 트리거되므로, 보이는 것은 현재 파일시스템과 조정된 레지스트리이며 오래된 스냅샷이 아닙니다.

## runtime이 주입하는 것

Agent는 브라우저 구성을 직접 선택하지 않습니다. 브라우저 Job이 시작되기 전에 runtime은 Job에 필요한 모든 것을 주입하며, 그 값은 Agent에게 불투명하다:

- runtime이 소유한 브라우저 세션으로의 **불투명한 route**
- **최종 browser material** (Agent가 구동할 준비된 세션)
- CLI가 통신하는 **데몬 소켓**
- 스크린샷과 기타 출력물을 위한 **아티팩트 루트**

Agent는 이 값들을 `ankole-browser` CLI를 통해 사용합니다. `app/agent_computer/src/browser-runtime/index.ts`의 `BrowserRuntime` 클래스가 materializer, 데몬 슈퍼바이저, 웹 fetch 어댑터를 소유하므로 브라우저 세션의 수명 주기는 runtime의 책임입니다. Agent의 책임은 CLI를 호출하는 것입니다.

## 제약: 브라우저 소유자는 하나

이것이 Agent가 어겨서는 안 되는 규칙입니다. runtime이 브라우저 소유자입니다. Agent는 반드시:

- **모든 것에 사전 구성된 `ankole-browser` CLI를 사용해야 한다** — open, snapshot, click, fill, screenshot, batch, 그리고 Playwright 스크립트용 `run`.
- **Chromium을 직접 실행하면 안 된다.**
- **`chromium.connectOverCDP`를 호출하거나** 프로필 이름, 자격 증명, provider 구성, CDP 엔드포인트, 컨트롤 플레인 식별자를 찾아서는 안 된다.

이유는 복구입니다. runtime은 데몬 슈퍼바이저, materializer, 세션 복구 경로를 소유합니다. 두 번째 브라우저 소유자 — Agent가 띄운 Chromium이나 Agent가 연 CDP 연결 — 는 그 경로밖에 있다. runtime이 세션을 복구, 체크포인트, 또는 내려치기하려고 할 때 Agent의 사이드 채널을 볼 수도 제어할 수도 없으므로 세션은 일관되지 않은 상태로 끝납니다. 사전 구성된 CLI는 유일한 소유 진입점이며, Agent가 접촉해야 하는 유일한 경로입니다.

## Agent가 브라우저를 구동하는 방법

`ankole-browser` CLI는 Agent에게 작업의 형태에 따라 선택하는 세 가지 실행 표면을 제공합니다:

- 탐색과 한두 개의 결정적 동작을 위한 **짧은 CLI 명령** — `open`, `snapshot -i`, `click @e2`, `fill @e4 "value"`, `screenshot`.
- 알려진 짧은 시퀀스를 위한 **`batch`** — 따옴표로 묶은 명령이나 argv 배열의 배열을 stdin으로 받아 개별 명령과 같은 파서를 적용합니다.
- 루프, 분기, 반복 추출, 팝업 또는 다운로드 조정, 정밀한 대기, 여러 값을 메모리에 보관해야 하는 작업에는 ESM JavaScript 파일용 **`run`**. `run`은 네이티브 Playwright 객체를 CLI 명령이 사용하는 것과 동일한 물리적 브라우저 세션에 연결하므로 스크립트와 CLI 단계는 하나의 세션을 공유합니다.

마지막 점이 중요하다: `run`은 두 번째 브라우저를 열지 않습니다. runtime이 소유한 세션을 재사용하므로 단일 소유자 규칙은 Playwright 스크립트 안에서도 성립합니다.

## 운영자가 건드리지 않는 것

워커 이미지가 브라우저 환경 변수를 설정합니다. 여기에는 `ANKOLE_BROWSER_CHROMIUM_EXECUTABLE`, `ANKOLE_BROWSER_CHROMIUM_ARGS_JSON`, `ANKOLE_BROWSER_DAEMON_SOCKET`, `ANKOLE_BROWSER_DAEMON_ENTRY`, `ANKOLE_BROWSER_CLI`, `ANKOLE_BROWSER_NODE`, `ANKOLE_BROWSER_RUNNER`가 포함됩니다. Console의 **Environment variables**에서 이 이름들을 재정의할 수 없다. 다른 브라우저 동작이 필요하면 Skill을 변경하세요.

## 다음 단계

- 브라우저를 켜는 Skill과 활성화 모델에 대해서는 [Agent Library](../agent-library/)를 읽으세요.
- 더 가벼운 대안 — 브라우저 없이 검색과 텍스트 fetch — 은 [Web tools](../web-tools/)를 읽으세요.
- 브라우저를 실행하는 Job에 대해서는 [Background Agent Jobs](../background-jobs/)를 읽으세요.
