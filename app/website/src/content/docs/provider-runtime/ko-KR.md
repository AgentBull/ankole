---
title: Provider 런타임
description: AIGateway가 selector를 provider로 해석하고, 준비된 요청을 만들고, kernel을 통해 디스패치하는 방법 — 모델 호출에서 provider 응답까지의 세 단계.
section: Developer guide
order: 119
---

모델 호출은 provider에 도달하기 전에 세 단계를 거칩니다: resolver가 selector를 provider 런타임 맵으로 바꾸고, provider 모듈이 준비된 요청을 만들고, kernel의 `UniversalAIClient`가 그것을 실행합니다. 이 페이지는 `ai_gateway/resolver.ex`, `providers.ex`, `universal_ai_request.ex`의 실제 코드에 대응하는 경로를 문서화합니다. [AIGateway](../ai-gateway/)와 [provider 추가](../adding-a-provider/) 위에 세워집니다.

resolver, provider 모듈, kernel은 각각 한 단계를 소유합니다. resolver는 selector, credential 풀 선택, OAuth refresh를 소유합니다. provider 모듈은 요청 준비를 소유합니다. kernel은 한 번의 와이어 시도를 소유합니다. control-plane의 시도 소유자는 다른 credential을 선택하고 요청을 다시 만들 수 있지만, kernel은 credential을 선택하거나 스스로 재시도하지 않습니다.

## 1단계: 해석(Resolver)

`Ankole.AIGateway.Resolver`는 요청의 `model` 필드를 구체적인 provider 런타임 맵으로 바꿉니다. 여기서 `primary`, `web_search.default`, 명시적인 `provider_id/model` 같은 subject용 selector가 provider id, provider kind, 업스트림 모델 이름, 해석된 런타임 설정이 됩니다.

Agent에는 8개의 내장 모델 프로필이 있습니다. `primary`, `light`, `heavy`, `coding`, `vision_fallback`, `web_search`, `web_fetch`, `image_generate`입니다. `coding`은 사용자에게 Background Agent Jobs로 보이는 프로필의 API 및 저장 이름입니다. 처음 5개 프로필은 언어 모델을 선택하고, 마지막 3개는 각각 웹 검색, 웹 가져오기, 이미지 생성 기능을 선택합니다.

Embedding과 rerank는 Agent 프로필이 아닙니다. 이 기능을 AIGateway에서 직접 호출하려면 명시적인 `provider_id/model` selector가 필요합니다. Brain은 [AppConfigure](../app-configuration/)의 `brain.embedding_model`과 `brain.rerank_model`에서 인스턴스 공용 모델을 읽습니다. 검색에 미치는 영향은 [Brain](../brain/)을 참조하십시오.

provider 행을 해석한 후 resolver는 사용 가능한 credential 하나를 선택합니다. thread affinity가 행의 `fill_first`, `round_robin`, `least_used`, `random` 전략보다 우선합니다. 런타임 맵은 정확한 credential ID를 이후의 모든 실패 경로에 전달합니다. ChatGPT 구독 OAuth 멤버의 경우 resolver는 provider 행 잠금 아래에서 만료 임박 또는 오래된 token을 refresh합니다. 영구적 refresh 실패는 그 멤버를 `dead`로 표시하고, 일시적 실패는 `exhausted`로 표시합니다. 둘 다 다음 사용 가능한 멤버를 선택합니다.

해석은 어떤 provider에도 접촉하기 전에 실패할 수 있습니다:

- `422 unknown_model_selector` — selector가 이 subject에 바인딩되어 있지 않습니다.
- `422 model_binding_not_configured` — capability와 이름은 바인딩되었지만 provider 행이 불완전합니다.

이 오류들은 누락된 모델 프로필, 사용할 수 없는 Provider, 또는 불완전한 Provider 구성을 식별합니다.

사용할 수 없는 credential 풀은 다릅니다. 각 현재 멤버의 안전 상태와 함께 `credential_pool_exhausted`를 반환합니다. 현재 exhausted된 멤버에 알려진 향후 복구 시간이 있을 때만 `retry_at`을 포함합니다.

## 2단계: 준비(Provider 모듈 + Providers)

런타임 맵이 해석되면 `Ankole.AIGateway.Providers`가 provider 모듈의 prepare 함수로 디스패치합니다. 엔트리포인트는 capability로 타입이 지정됩니다:

```elixir
build_response_request(runtime, request)    # :language_model
build_embeddings_request(runtime, request)  # :embedding_model
build_rerank_request(runtime, request)      # :rerank_model
build_web_search_request(runtime, request)  # :web_search
build_web_fetch_request(runtime, request)   # :web_fetch
build_image_generate_request(runtime, request) # :image_generate
```

각각은 `build_prepared_request/4`에 위임합니다. 이 함수는 provider의 `ProviderDefinition`에서 capability를 조회하고, provider가 그것을 지원하는지 검증하며(`supports_capability?/2`), capability의 `prepare` 함수를 호출합니다. 이것은 해석된 설정과 요청에서 `UniversalAIRequest` 구조체를 만드는 일반 Elixir 함수입니다. 준비된 요청은 선택된 credential ID가 있는 control-plane 전용 재빌드 컨텍스트를 유지합니다. 이 컨텍스트는 요청이 네이티브 경계를 넘기 전에 제거됩니다.

provider 차이점이 사는 단계가 바로 여기입니다: URL 구성, auth 헤더, 본문 형성, 특정 업스트림 API의 특이함. 준비된 요청은 `UniversalAIRequest` — path, `api_resolver` atom, 헤더, provider 옵션을 가진 구조체 — 이지 HTTP 호출이 아닙니다.

## 3단계: 실행(UniversalAIRequest → kernel)

`UniversalAIRequest`는 AIGateway에서 kernel의 `UniversalAIClient`로 가는 얇은 실행 어댑터입니다. provider 모듈이 요청 사양을 준비하고, 어댑터가 그것을 실행하며, Phoenix 호출자가 기대하는 HTTP/SSE-ready 경계를 보존합니다.

실행은 준비된 요청을 Rust kernel에 넘기며, kernel은 다음을 수행합니다:

- `api_resolver`를 와이어 프로토콜(인코딩, 전송)로 해석하고,
- 업스트림 연결을 엽니다(capability의 `upstream`이 선언한 대로 HTTP SSE, EventStream, WebSocket, 또는 일반 JSON),
- provider의 auth와 헤더로 요청을 보내고,
- 응답 스트림을 받고,
- 다운스트림 chunk 형식으로 정규화합니다.

kernel은 성공과 실패 모두에서 제한된 응답 헤더 집합을 반환합니다. 여기에는 `x-codex-*` 레이트 제한 계열과 `cf-mitigated`가 포함되지만, credential, 쿠키, 기타 provider 헤더는 제외됩니다. control plane은 이 집합을 쿨다운, 레이트 제한 투영, Cloudflare challenge 진단에 사용합니다.

`CredentialAttempts`는 각 kernel 시도를 감쌉니다. 귀속 가능한 `429`, `5xx`, 또는 전송 실패는 그 시도를 한 credential만 표시하고, 다른 정상 멤버를 선택하고, 인가와 provider 헤더를 재구성하고, 지수 백오프와 지터로 기다린 다음, kernel에 새 시도 하나를 요청합니다. 단일 사용 가능 멤버는 같은 credential로 한 번 재시도합니다. credential ID 없는 실패는 어떤 멤버도 표시하지 않고 풀 한 바퀴 후에 멈춥니다. 모든 멤버를 사용할 수 없으면 시도 소유자는 `credential_pool_exhausted`를 반환합니다. 다른 provider로 전환하지 않습니다.

이것이 [Kernel](../kernel/) 페이지가 문서화하는 단계입니다: Rust의 `universal_ai_client` 모듈, 그 전송, demand credit, 취소. provider 모듈은 실행에 참여하지 않습니다.

## 실패가 어떻게 드러나는가

각 단계는 별개의 오류 클래스를 만듭니다:

| 단계 | 실패 형태 | 의미 |
|---|---|---|
| 해석 | `422 unknown_model_selector` / `model_binding_not_configured` | selector 또는 바인딩이 잘못됨 — 구성 문제이며 일시적이지 않음 |
| Credential 풀 | `429 credential_pool_exhausted` | 모든 멤버가 비활성, dead, 또는 쿨다운 중. `retry_at`이 있으면 그때까지 기다리고, 없으면 풀을 복구 |
| 준비 | `422 unsupported_capability` / provider 특정 검증 | provider가 이 capability를 제공하지 않거나 요청 옵션이 유효하지 않음 |
| 실행 | `502 upstream_response_failed` / `504 upstream_timeout` | provider가 오류를 반환했거나 시간 초과 — 일시적일 수 있음 |

오류 클래스는 호출자에게 구성을 고칠지(422), 기다렸다 재시도할지(502/504), provider를 조사할지를 알려줍니다. [AIGateway](../ai-gateway/) 페이지가 전체 오류 봉투를 문서화합니다.

## 레지스트리와 플러그인 기여 provider

`Providers`의 provider 레지스트리는 컴파일된 `ProviderDefinition` 구조체들을 보관합니다. 퍼스트파티 provider는 컴파일 시 포함되고, 플러그인 기여 provider는 `ai_gateway.provider` 계약으로 도착하며, `refresh_from_adapter_declarations/1`이 그것들을 레지스트리에 병합합니다. provider kind는 `~r/\A[a-z][a-z0-9_]{0,62}\z/`와 일치해야 하고, 레지스트리는 병합된 집합을 캐시하므로 해석이 호출마다 플러그인을 다시 스캔하지 않습니다.

## 이 가이드가 아닌 것

provider 작성 튜토리얼이 아닙니다 — DSL, 정의, prepare 함수는 [provider 추가](../adding-a-provider/)를 참조하세요. 와이어 프로토콜 레퍼런스도 아닙니다 — kernel이 와이어를 소유하며, 그것은 [Kernel](../kernel/) 페이지입니다. 그리고 세 모듈을 읽는 것의 대체물도 아닙니다. 이 페이지는 그 모듈들을 통과하는 경로입니다.

## 다음 단계

- provider 작성 방법은 [provider 추가](../adding-a-provider/)를 읽으세요.
- AIGateway 개념 페이지(엔드포인트, 오류 형태)는 [AIGateway](../ai-gateway/)를 읽으세요.
- 요청을 실행하는 kernel은 [Kernel](../kernel/)을 읽으세요.
- 첫 모델 프로필 설정은 [Quick start](../quickstart/#llm-providers)를 읽으세요.
