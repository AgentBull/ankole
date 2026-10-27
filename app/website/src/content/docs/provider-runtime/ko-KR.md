---
title: Provider 런타임
description: AIGateway가 selector를 provider로 해석하고, 준비된 요청을 만들고, kernel을 통해 디스패치하는 방법 — 모델 호출에서 provider 응답까지의 세 단계.
section: Developer guide
order: 119
---

모델 호출이 실제 업스트림 provider에 도달하기까지는 세 단계를 거칩니다. 먼저 resolver가 selector를 구체적인 provider 런타임 맵으로 해석하고, 이어서 provider 모듈이 전송 가능한 요청 구조체를 조립한 뒤, 마지막으로 kernel의 `UniversalAIClient`가 실제 네트워크 호출을 수행합니다. 이 문서는 `ai_gateway/resolver.ex`, `providers.ex`, `universal_ai_request.ex`의 실제 코드를 따라 이 세 단계를 설명하며, [AIGateway](../ai-gateway/) 및 [provider 추가](../adding-a-provider/) 문서에서 다룬 개념을 바탕으로 합니다.

resolver, provider 모듈, kernel은 각자 한 단계씩만 전담합니다. resolver는 selector 해석, 자격 증명 풀 선택, OAuth 토큰 갱신을 맡고, provider 모듈은 요청 조립을 맡으며, kernel은 단일 와이어 전송 시도를 맡습니다. 재시도가 필요할 때는 control plane의 시도 소유자가 다른 자격 증명을 골라 요청을 다시 조립하며, kernel이 임의로 자격 증명을 바꾸거나 자체 재시도를 수행하지는 않습니다.

## 1단계: 해석(Resolver)

`Ankole.AIGateway.Resolver`는 요청의 `model` 필드를 구체적인 provider 런타임 맵으로 변환합니다. 이 단계에서 `primary`, `web_search.default`, 또는 명시적인 `provider_id/model` 같은 호출 주체별 selector가 실제 provider ID, provider 종류, 업스트림 모델 이름, 해석된 런타임 설정으로 결정됩니다.

Agent에는 `primary`, `light`, `heavy`, `coding`, `vision_fallback`, `web_search`, `web_fetch`, `image_generate`까지 총 8개의 내장 모델 프로필이 있습니다. 이 중 `coding`은 화면에서 Background Agent Jobs로 표시되는 프로필의 내부 API 및 저장소 이름입니다. 앞의 5개 프로필은 언어 모델을 지정하고, 뒤의 3개 프로필은 각각 웹 검색, 웹 페이지 읽기, 이미지 생성 기능을 지정합니다.

Embedding과 rerank는 개별 Agent 프로필에 속하지 않으므로, AIGateway에서 직접 호출할 때는 명시적인 `provider_id/model` selector를 전달해야 합니다. Brain의 경우 [AppConfigure](../app-configuration/)의 `brain.embedding_model`에서 사이트 단위 embedding 모델을 읽고, `brain.rerank_model`에서 테넌트 단위 rerank 모델을 읽습니다. 검색 동작에 미치는 영향은 [Brain](../brain/)을 참조하십시오.

대상 provider 행이 결정되면 resolver는 풀에서 사용 가능한 자격 증명(credential) 하나를 고릅니다. 이때 스레드 고정성(thread affinity)이 행에 설정된 `fill_first`, `round_robin`, `least_used`, `random` 분배 전략보다 우선 적용되며, 선택된 자격 증명 ID는 이후 실패 처리 경로 전체로 전달되도록 런타임 맵에 기록됩니다. ChatGPT 구독 OAuth 멤버를 사용하는 경우에는 provider 행 잠금 안에서 만료가 임박했거나 이미 만료된 토큰을 갱신합니다. 갱신이 영구적으로 실패하면 해당 멤버를 `dead`로, 일시적으로 실패하면 `exhausted`로 표시한 뒤 사용 가능한 다음 멤버로 넘어갑니다.

해석 단계에서는 업스트림 provider에 연결하기 전에 다음과 같은 오류가 먼저 반환될 수 있습니다.

- `422 unknown_model_selector`: 해당 호출 주체에 바인딩되지 않은 selector를 요청한 경우입니다.
- `422 model_binding_not_configured`: 기능과 프로필 이름은 바인딩되어 있으나 연결된 provider 행 설정이 불완전한 경우입니다.

이러한 오류를 통해 누락된 모델 프로필, 비활성화된 Provider, 미완성 Provider 설정을 바로 구분할 수 있습니다.

반면 자격 증명 풀 내 모든 멤버를 사용할 수 없는 상황은 별도로 처리되어, 현재 각 멤버의 안전 상태 정보와 함께 `credential_pool_exhausted`를 반환합니다. 현재 `exhausted` 상태인 멤버 중 알려진 복구 예정 시각이 있는 경우에만 응답에 `retry_at`이 포함됩니다.

## 2단계: 준비(Provider 모듈 + Providers)

런타임 맵 해석이 끝나면 `Ankole.AIGateway.Providers`가 해당 provider 모듈의 요청 준비 함수로 제어를 넘깁니다. 진입점 함수는 기능(capability) 종류에 따라 나뉩니다.

```elixir
build_response_request(runtime, request)    # :language_model
build_embeddings_request(runtime, request)  # :embedding_model
build_rerank_request(runtime, request)      # :rerank_model
build_web_search_request(runtime, request)  # :web_search
build_web_fetch_request(runtime, request)   # :web_fetch
build_image_generate_request(runtime, request) # :image_generate
```

각 함수는 내부적으로 `build_prepared_request/4`를 호출합니다. 이 함수는 대상 provider의 `ProviderDefinition`에서 요청한 capability를 찾아 지원 여부를 검증(`supports_capability?/2`)한 뒤, 해당 capability의 `prepare` 함수를 실행해 해석된 설정과 원본 요청으로부터 `UniversalAIRequest` 구조체를 생성합니다. 생성된 구조체에는 선택된 자격 증명 ID를 담은 control-plane 전용 재조립 컨텍스트가 포함되며, 이 컨텍스트는 네이티브 Rust 경계를 넘어가기 직전에 제거됩니다.

URL 조합, 인증 헤더 구성, 요청 본문 포맷 변환, 업스트림 API별 고유 규격 처리처럼 Provider마다 달라지는 차이는 모두 이 단계에서 캡슐화됩니다. 여기서 만들어지는 `UniversalAIRequest`는 경로, `api_resolver` atom, 헤더, provider 옵션을 담은 순수 데이터 구조체일 뿐, 아직 실제 HTTP 요청을 보낸 상태는 아닙니다.

## 3단계: 실행(UniversalAIRequest → kernel)

`UniversalAIRequest`는 AIGateway와 Rust kernel의 `UniversalAIClient` 사이를 잇는 얇은 실행 어댑터입니다. provider 모듈이 요청 사양을 준비하면 이 어댑터가 실행을 위임하며, Phoenix 호출자가 기대하는 HTTP/SSE 스트리밍 경계를 그대로 유지합니다.

준비된 요청을 넘겨받은 Rust kernel은 다음 작업을 순서대로 수행합니다.

- `api_resolver` 값을 실제 와이어 프로토콜(인코딩 및 전송 방식)로 매핑합니다.
- capability의 `upstream` 선언에 따라 HTTP SSE, EventStream, WebSocket 또는 일반 JSON 연결을 엽니다.
- provider 인증 정보와 헤더를 실어 업스트림 요청을 전송합니다.
- 업스트림 응답 스트림을 수신합니다.
- 수신한 데이터를 다운스트림 청크 형식으로 정규화해 반환합니다.

요청이 성공하든 실패하든 kernel은 허용된 일부 응답 헤더만 추려서 반환합니다. 여기에는 `x-codex-*` 속도 제한 헤더 계열과 `cf-mitigated`가 포함되며, 민감한 자격 증명이나 쿠키, 그 밖의 임의 provider 헤더는 제외됩니다. control plane은 반환된 헤더를 바탕으로 쿨다운 계산, 속도 제한 상태 투영, Cloudflare 챌린지 진단을 수행합니다.

각 kernel 호출 바깥은 `CredentialAttempts`가 감싸고 있습니다. 특정 자격 증명에 귀속할 수 있는 `429`, `5xx` 또는 전송 오류가 발생하면 해당 시도에 쓰인 자격 증명만 상태 표시를 남긴 뒤, 다른 정상 멤버를 골라 인증 및 provider 헤더를 다시 조립하고 지터(jitter)가 적용된 지수 백오프만큼 대기한 다음 kernel에 새 시도를 요청합니다. 사용 가능한 멤버가 하나뿐이라면 동일한 자격 증명으로 한 번 재시도합니다. 자격 증명 ID를 특정할 수 없는 실패가 발생하면 어떤 멤버에도 표시를 남기지 않으며, 풀 전체를 한 바퀴 순회한 뒤 중단합니다. 사용 가능한 멤버가 전혀 남지 않으면 다른 provider로 임의 전환하지 않고 `credential_pool_exhausted`를 반환합니다.

이 실행 계층의 내부 동작인 Rust `universal_ai_client` 모듈, 전송 프로토콜, 수요 크레딧(demand credit), 취소 처리는 [Kernel](../kernel/) 문서에서 자세히 다루며, 개별 provider 모듈은 이 단계에 관여하지 않습니다.

## 실패가 어떻게 드러나는가

단계마다 반환되는 오류 범주가 명확히 구분됩니다.

| 단계 | 실패 형태 | 의미 |
|---|---|---|
| 해석 | `422 unknown_model_selector` / `model_binding_not_configured` | selector 또는 바인딩 설정 오류(일시적 장애가 아닌 구성 문제) |
| Credential 풀 | `429 credential_pool_exhausted` | 모든 멤버가 비활성화, `dead` 또는 쿨다운 상태(`retry_at`이 있으면 대기 후 재시도, 없으면 풀 복구 필요) |
| 준비 | `422 unsupported_capability` / provider별 검증 오류 | 해당 provider가 기능을 지원하지 않거나 요청 옵션이 유효하지 않음 |
| 실행 | `502 upstream_response_failed` / `504 upstream_timeout` | 업스트림 provider 오류 응답 또는 타임아웃(일시적 장애일 수 있음) |

호출자는 이 오류 분류를 보고 설정을 고쳐야 할지(`422`), 잠시 기다렸다 재시도할지(`502`/`504`), 혹은 provider 상태를 점검해야 할지 바로 판단할 수 있습니다. 전체 오류 응답 봉투(envelope) 규격은 [AIGateway](../ai-gateway/) 문서를 참조하세요.

## 레지스트리와 플러그인 기여 provider

`Providers` 내부의 provider 레지스트리는 컴파일된 `ProviderDefinition` 구조체들을 관리합니다. 퍼스트파티 provider는 컴파일 시점에 포함되고, 플러그인이 제공하는 provider는 `ai_gateway.provider` 계약을 통해 전달되어 `refresh_from_adapter_declarations/1` 호출 시 레지스트리에 병합됩니다. 모든 provider kind 식별자는 `~r/\A[a-z][a-z0-9_]{0,62}\z/` 정규식을 만족해야 하며, 병합된 결과는 캐시되므로 매 모델 호출마다 플러그인을 다시 스캔하지 않습니다.

## 이 가이드가 아닌 것

이 문서는 새 provider를 직접 구현하는 튜토리얼이 아니므로, 선언 DSL과 `prepare` 함수 작성법은 [provider 추가](../adding-a-provider/)를 참조하세요. 또한 와이어 프로토콜 상세 명세는 전송 계층을 소유하는 [Kernel](../kernel/) 문서에서 다룹니다. 이 문서는 세 핵심 모듈을 따라 모델 호출이 흘러가는 전체 경로를 파악하기 위한 안내서입니다.

## 다음 단계

- 새 provider 작성 방법은 [provider 추가](../adding-a-provider/)를 참조하세요.
- AIGateway 엔드포인트와 오류 형식은 [AIGateway](../ai-gateway/)를 참조하세요.
- 요청을 실제 전송하는 네이티브 계층은 [Kernel](../kernel/)을 참조하세요.
- 첫 모델 프로필 설정 절차는 [Quick start](../quickstart/#llm-providers)를 참조하세요.
