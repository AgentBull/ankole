---
title: Provider 추가
description: AIGateway Provider를 선언하는 방법 — DSL, 컴파일된 정의, 설정, Capability, prepare 함수, 플러그인 기반 등록.
section: Developer guide
order: 115
---

AIGateway Provider는 Ankole이 업스트림 AI 서비스 — LLM, 임베딩 모델, 웹 검색 API — 와 통신하는 방식입니다. 이 페이지는 기여자용 워크스루다: Provider DSL, 그것이 생성하는 컴파일된 `ProviderDefinition`, Provider가 선언하는 설정과 Capability, 그리고 요청 구성을 소유하는 prepare 함수. [AIGateway](../ai-gateway/) 개념 페이지의 연장이며, 여기서 다루는 것은 *Provider를 추가하는 방법*이다.

핵심 속성을 먼저 명시합니다: Provider 모듈은 Elixir에서 요청 준비를 소유하고, Rust `UniversalAIClient`는 유선 — 전송, 인코딩, 응답 정규화 — 을 소유합니다. 컴파일된 정의는 안정적인 메타데이터, 설정, 그리고 각 Capability를 소유하는 prepare 함수만 기술합니다. Provider는 완전한 HTTP 클라이언트가 아니라 prepare 함수와 선언의 조합입니다.

## Provider DSL

Provider 모듈은 `Ankole.AIGateway.ProviderDSL`을 사용하고, 작은 블록 구조의 DSL로 자신을 선언합니다. DSL은 메타데이터와 Capability 소유권을 기록합니다. 요청 본문 필드는 의도적으로 기술하지 않습니다 — 각 Provider의 prepare 함수는 같은 모듈 안의 일반 Elixir 코드입니다.

```elixir
defmodule Ankole.AIGateway.Providers.MyProvider do
  use Ankole.AIGateway.ProviderDSL

  provider :my_provider do
    label(%{"default" => "My Provider"})
    base_url("https://api.example.com/v1")

    setting(:api_key, encrypted: true, scope: :credential)

    language_model do
      upstream(:sse)
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

`provider` 블록은 `ProviderDefinition` 구조체로 컴파일되며, runtime에서 AIGateway 레지스트리가 소비합니다.

## 컴파일된 정의

`ProviderDefinition`은 다음을 담는다:

| 필드 | 의미 |
|---|---|
| `provider_kind` | 저장된 Provider 행과 모델 바인딩이 사용하는 안정적인 id |
| `label` | Console용 지역화된 표시 이름 |
| `module` | Provider 모듈 자체 |
| `base_url` | 기본 업스트림 URL(운영자가 재정의 가능) |
| `settings` | 선언된 `Setting` 목록 |
| `capabilities` | 선언된 `Capability` 목록 |

레지스트리는 `provider_kind`로 Provider를 찾고, 요청된 종류에 해당하는 Capability를 조회한 다음, 그 Capability의 `prepare` 함수를 호출하고 결과를 `UniversalAIClient`에 넘깁니다.

## 설정

`Setting`은 운영자 또는 요청 옵션 하나를 선언합니다:

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
| `options` | `:select`의 경우 허용되는 값 |
| `required?` | 운영자가 반드시 제공해야 하는지 여부 |
| `encrypted?` | 저장 시 암호화되는 자격 증명 값에 대한 스토리지 메타데이터 |
| `advanced?` | Console 폼용 표시 메타데이터. 검증이나 runtime 동작은 바꾸지 않는다 |
| `scope` | `:credential` (풀 구성원마다), `:connection` (Provider 행마다), 또는 `:request` (모델 프로필마다) |

모든 Provider 행에는 구성원이 하나뿐인 경우를 포함해 자격 증명 풀이 있다. 리졸버는 prepare 함수를 호출하기 전에 건강한 구성원 하나를 선택하고 그 `:credential` 설정을 복호화합니다. 엔드포인트와 커스텀 헤더 같은 connection 설정은 행 전체가 공유합니다. request 설정은 모델 프로필에서 온다. prepare 함수는 세 scope를 모두 해석된 설정 맵에서 읽으며 풀 선택을 구현하지 않습니다.

`advanced?`는 표시 전용입니다. Console에서 필드를 고급 토글 뒤에 숨기며 검증이나 동작은 바꾸지 않습니다.

## 역량

`Capability`은 사용자에게 노출되는 모델 기능을 prepare 함수와 유선 형태에 묶는다:

```elixir
language_model do
  upstream(:sse)
  api_resolver(:openai_responses)
  prepare(:prepare_language_model)
  supports_parallel_tool_calls()
  supports_native_image_generation()
end
```

| 필드 | 의미 |
|---|---|
| `kind` | `:language_model`, `:embedding_model`, `:rerank_model`, `:web_search`, `:web_fetch`, `:image_generate` 중 하나 |
| `upstream` | 유선 형태: `:sse`, `:eventstream`, `:websocket_text`, 또는 `:json` |
| `api_resolver` | 인코딩과 전송을 소유하는 Rust 쪽 리졸버 atom(예: `:openai_responses`) |
| `prepare` | 준비된 요청을 만드는 Elixir 함수 |
| `timeout_ms` | Capability별 선택적 타임아웃 |
| `supports_parallel_tool_calls?` | Provider가 병렬 tool 호출을 받아들이는지 여부 |
| `supports_native_image_generation?` | 호스팅된 `image_generate` 프로필 없이 LLM이 공용 이미지 tool을 실행할 수 있는지 여부 |

여섯 가지 Capability 종류는 runtime이 사용하는 외부 이름에 매핑된다: `language_model` → `"llm"`, `embedding_model` → `"embedding"`, `rerank_model` → `"rerank"`, 그리고 세 가지 웹/이미지 종류는 그대로입니다. LLM만 제공하는 Provider는 `language_model`만 선언하고, LLM과 임베딩을 모두 제공하는 Provider는 둘 다 선언합니다.

## prepare 함수

prepare 함수는 Capability의 `prepare` 필드가 이름을 정하는, Provider 모듈 안의 일반 Elixir 코드입니다. `PrepareContext` (해석된 설정, 모델 요청, Agent의 컨텍스트)를 받아 `UniversalAIClient`가 보내는 준비된 요청을 반환합니다:

```elixir
def prepare_language_model(%PrepareContext{} = context) do
  %UniversalAIRequest{}
  |> put_url(context.settings.base_url, "/responses")
  |> put_auth("Bearer", context.settings.api_key)
  |> put_body(context.request)
end
```

여기에 Provider의 차이가 산다 — URL 구성, 인증 헤더, 본문 형태, 특정 업스트림 API의 규칙. prepare 함수가 Provider의 실제 작업이고, DSL 선언은 그 작업이 발견되고 라우팅되는 방식입니다. 자격 증명 재시도는 이 함수밖에 남는다: 컨트롤 플레인이 다른 구성원을 선택하고, 요청을 다시 만들고, 커널에 전송 시도 한 번을 새로 수행하도록 요청할 수 있다.

## Provider 등록

퍼스트 파티 Provider는 릴리스에 컴파일되어 레지스트리가 발견합니다. 플러그인 기여 Provider는 Control Plane Plugin의 `adapter_declarations/0`에서 `ai_gateway.provider` 계약으로 선언하고, 레지스트리는 플러그인의 선언에서 이를 가져옵니다 — 시그널 어댑터와 같은 모델, 다른 계약 id.

Plugin 등록은 [Skill 및 Control Plane Plugin 개발](../writing-a-skill/)을 보라. Provider 계약은 `ai_gateway.provider`이며, kind id는 `~r/\A[a-z][a-z0-9_]{0,62}\z/`와 일치해야 한다.

## 이 가이드가 아닌 것

이것은 HTTP 클라이언트 튜토리얼이 아닙니다 — prepare 함수는 준비된 요청을 만들뿐 HTTP는 Rust 클라이언트가 한다. 커널의 전송을 우회하는 방법도 아닙니다 — `api_resolver`와 `upstream` 유선 형태는 Rust `UniversalAIClient`가 소유하는 것이며, Provider는 새 전송을 발명하는 대신 기존 리졸버에서 선택합니다. 그리고 기존 Provider를 읽는 것의 대체재도 아닙니다 — `lib/ankole/ai_gateway/providers/`가 표준 참조이며, 가장 단순한 것(OpenAI 또는 openai_compatible)이 올바른 출발점입니다.

## 다음 단계

- AIGateway 개념 (라우팅, 해석, 통합 경계)은 [AIGateway](../ai-gateway/)를 읽으세요.
- Plugin 등록은 [Skill 및 Control Plane Plugin 개발](../writing-a-skill/)을 읽으세요.
- 첫 Provider 설정은 [빠른 시작](../quickstart/#3-add-an-llm-provider-and-create-an-agent)을 읽으세요.
