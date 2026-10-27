---
title: Provider 추가
description: AIGateway Provider를 선언하는 방법 — DSL, 컴파일된 정의, 설정, Capability, prepare 함수, 플러그인 기반 등록.
section: Developer guide
order: 115
---

AIGateway Provider는 Ankole이 LLM, 임베딩 모델, 웹 검색 API 같은 업스트림 AI 서비스와 통신할 때 사용하는 어댑터 계층입니다. 이 문서는 기여자를 위한 구현 가이드로서 Provider DSL과 컴파일 결과물인 `ProviderDefinition`, 설정 및 Capability 선언 방식, 그리고 요청 조립을 담당하는 prepare 함수를 차례대로 살펴봅니다. [AIGateway](../ai-gateway/) 개념 문서의 연장선에서 *새 Provider를 실제로 추가하는 방법*에 초점을 맞춥니다.

먼저 핵심 역할을 구분해 두겠습니다. Elixir의 Provider 모듈은 요청 준비(request preparation)만 담당하며, 실제 네트워크 전송, 인코딩, 응답 정규화는 Rust의 `UniversalAIClient`가 전담합니다. 컴파일된 정의에는 고정 메타데이터와 설정, 그리고 각 Capability의 요청을 조립할 prepare 함수만 기록됩니다. 즉, Provider는 독립된 HTTP 클라이언트가 아니라 선언부와 prepare 함수의 조합입니다.

## Provider DSL

Provider 모듈에서는 `Ankole.AIGateway.ProviderDSL`을 불러온 뒤 간결한 블록형 DSL로 사양을 선언합니다. 이 DSL은 메타데이터와 지원 Capability만 기술하며 요청 본문 필드는 의도적으로 다루지 않습니다. 실제 요청 본문은 같은 모듈 안에 일반 Elixir 함수로 작성하는 prepare 함수에서 구성합니다.

```elixir
defmodule Ankole.AIGateway.Providers.MyProvider do
  use Ankole.AIGateway.ProviderDSL

  provider :my_provider do
    label(%{"default" => "My Provider"})
    base_url("https://api.example.com/v1")

    setting(:api_key, encrypted: true, scope: :credential)

    language_model do
      api_resolver(:openai_responses)
      prepare(:prepare_language_model)
      supports_parallel_tool_calls()
    end
  end

  def prepare_language_model(context) do
    # normal Elixir — build the prepared request from the context
  end
end
```

`provider` 블록은 컴파일 시점에 `ProviderDefinition` 구조체로 변환되며, 런타임에 AIGateway 레지스트리에서 이를 읽어들입니다.

## 컴파일된 정의

`ProviderDefinition` 구조체는 다음 필드를 포함합니다.

| 필드 | 의미 |
|---|---|
| `provider_kind` | 저장된 Provider 행과 모델 바인딩에서 참조하는 고유 식별자 |
| `label` | Console에 표시할 다국어 이름 |
| `module` | 해당 Provider를 정의한 Elixir 모듈 |
| `base_url` | 기본 업스트림 URL(운영자가 재정의 가능) |
| `settings` | 선언된 `Setting` 목록 |
| `capabilities` | 선언된 `Capability` 목록 |

AIGateway 레지스트리는 `provider_kind`로 Provider를 찾고 요청된 작업 종류에 맞는 Capability를 조회한 뒤, 해당 Capability의 `prepare` 함수를 호출하여 반환된 요청을 `UniversalAIClient`에 전달합니다.

## 설정

각 `Setting`은 운영자가 구성하거나 요청 시점에 지정하는 단일 옵션을 선언합니다.

```elixir
setting(:api_key, encrypted: true, scope: :credential)
setting(:organization, advanced: true)
setting(:reasoningEffort, type: :select, default: "high",
       options: ["minimal", "low", "medium", "high", "xhigh"], scope: :request)
```

| 필드 | 의미 |
|---|---|
| `key` | 옵션 이름(atom) |
| `type` | `:string`, `:select`, `:boolean`, `:map` 또는 nil |
| `default` | 기본값 |
| `options` | `:select` 타입에서 허용하는 선택지 목록 |
| `required?` | 운영자가 반드시 입력해야 하는지 여부 |
| `encrypted?` | 저장 시 암호화해야 하는 자격 증명 값인지 나타내는 스토리지 메타데이터 |
| `advanced?` | Console 설정 화면용 표시 메타데이터로, 검증이나 런타임 동작에는 영향을 주지 않음 |
| `scope` | `:credential`(풀 항목별), `:connection`(Provider 행별), `:request`(모델 프로필별) |

자격 증명이 하나뿐인 경우를 포함해 모든 Provider 행은 자격 증명 풀을 가집니다. 리졸버는 prepare 함수를 호출하기 전에 정상 상태인 풀 구성원 하나를 골라 `:credential` 범위 설정을 복호화합니다. 엔드포인트나 커스텀 헤더 같은 `:connection` 설정은 해당 Provider 행 전체에서 공유되며, `:request` 설정은 모델 프로필에서 전달됩니다. 따라서 prepare 함수는 이미 병합·해석된 설정 맵에서 세 범위의 값을 읽기만 하면 되며, 풀 선택 로직을 직접 구현할 필요가 없습니다.

`advanced?`는 화면 표시 전용 옵션입니다. Console에서 해당 필드를 고급 설정 토글 아래로 접어 둘 뿐이며, 유효성 검사나 런타임 동작은 바꾸지 않습니다.

## 역량

`Capability`는 사용자에게 노출되는 모델 기능을 특정 prepare 함수 및 전송 형식과 연결합니다.

```elixir
language_model do
  api_resolver(:openai_responses)
  prepare(:prepare_language_model)
  supports_parallel_tool_calls()
  supports_native_image_generation()
end
```

| 필드 | 의미 |
|---|---|
| `kind` | `:language_model`, `:embedding_model`, `:rerank_model`, `:web_search`, `:web_fetch`, `:image_generate` 중 하나 |
| `upstream` | 전송 형식. `kind`에 따라 결정되며 `:language_model`은 `:sse`, 나머지는 모두 `:json` |
| `api_resolver` | 인코딩과 네트워크 전송을 담당하는 Rust 측 리졸버 atom(예: `:openai_responses`) |
| `prepare` | 전송할 요청 구조체를 조립하는 Elixir 함수 이름 |
| `timeout_ms` | Capability별 선택적 타임아웃(밀리초) |
| `supports_parallel_tool_calls?` | 업스트림 Provider가 병렬 도구 호출을 지원하는지 여부 |
| `supports_native_image_generation?` | 별도의 호스팅된 `image_generate` 프로필 없이 LLM이 공용 이미지 도구를 직접 실행할 수 있는지 여부 |

여섯 가지 Capability 종류는 런타임 외부 이름에 다음과 같이 대응합니다. `language_model`은 `"llm"`, `embedding_model`은 `"embedding"`, `rerank_model`은 `"rerank"`로 매핑되며, 나머지 웹 및 이미지 관련 세 종류는 이름을 그대로 사용합니다. LLM만 제공하는 Provider는 `language_model`만 선언하면 되고, LLM과 임베딩을 함께 제공한다면 두 블록을 모두 선언합니다.

## prepare 함수

prepare 함수는 Capability의 `prepare` 필드에 지정된 이름으로 Provider 모듈 안에 작성하는 일반 Elixir 함수입니다. 해석이 끝난 설정, 모델 요청, Agent 컨텍스트가 담긴 `PrepareContext`를 인자로 받아 `UniversalAIClient`가 전송할 `UniversalAIRequest`를 반환합니다.

```elixir
def prepare_language_model(%PrepareContext{} = context) do
  %UniversalAIRequest{}
  |> put_url(context.settings.base_url, "/responses")
  |> put_auth("Bearer", context.settings.api_key)
  |> put_body(context.request)
end
```

URL 조립, 인증 헤더, 요청 본문 구조, 특정 업스트림 API의 고유 규칙처럼 Provider마다 달라지는 처리는 모두 이 함수에 집중됩니다. 즉, 실제 변환 작업은 prepare 함수가 수행하고 DSL 선언은 레지스트리가 이 함수를 찾아 라우팅할 수 있게 해 줍니다. 자격 증명 재시도는 이 함수 바깥에서 이루어집니다. 전송이 실패해 재시도가 필요하면 컨트롤 플레인이 풀에서 다른 자격 증명을 고른 뒤 prepare 함수를 다시 호출해 새 요청을 만들고, 커널에 단일 전송을 다시 요청합니다.

## Provider 등록

퍼스트 파티 Provider는 릴리스에 함께 컴파일되어 레지스트리에 자동 등록됩니다. 플러그인으로 제공하는 Provider는 Control Plane Plugin의 `adapter_declarations/0`에서 `ai_gateway.provider` 계약으로 선언하며, 레지스트리가 플러그인 선언을 읽어 등록합니다. 계약 ID만 다를 뿐 시그널 어댑터 등록과 동일한 방식을 따릅니다.

플러그인 등록 절차는 [Skill 및 Control Plane Plugin 개발](../writing-a-skill/)을 참조하세요. Provider 계약 이름은 `ai_gateway.provider`이며, kind ID는 정규식 `~r/\A[a-z][a-z0-9_]{0,62}\z/`를 만족해야 합니다.

## 이 가이드가 아닌 것

이 문서는 HTTP 클라이언트 작성 튜토리얼이 아닙니다. prepare 함수는 요청 데이터만 조립하며 실제 HTTP 통신은 Rust 클라이언트가 수행합니다. 또한 커널 전송 계층을 우회하는 방법을 다루지도 않습니다. `api_resolver`와 `upstream` 전송 형식은 Rust `UniversalAIClient`가 관리하므로, 새 Provider를 작성할 때는 독자적인 전송 계층을 만드는 대신 기존 리졸버 중 하나를 선택해야 합니다. 마지막으로, 실제 코드 읽기를 대신할 수는 없습니다. `lib/ankole/ai_gateway/providers/` 디렉터리에 있는 기존 구현체 중 가장 단순한 OpenAI나 `openai_compatible` 모듈을 함께 살펴보는 것이 가장 빠른 출발점입니다.

## 다음 단계

- AIGateway의 전체 구조(라우팅, 해석, 통합 경계)는 [AIGateway](../ai-gateway/)를 참조하세요.
- 플러그인 등록 방법은 [Skill 및 Control Plane Plugin 개발](../writing-a-skill/)을 참조하세요.
- 첫 Provider 구성 절차는 [빠른 시작](../quickstart/#llm-providers)을 참조하세요.
