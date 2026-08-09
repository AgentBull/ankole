---
title: Provider の追加
description: AIGateway provider の宣言方法。DSL、コンパイルされた定義、設定、能力、prepare 関数、plugin ベースの登録について説明します。
section: Developer guide
order: 115
---

AIGateway provider は、Ankole が上流の AI service、つまり LLM、embedding model、web 検索 API と通信する方法です。このページは contributor 向けの walkthrough です。provider DSL、それが生成するコンパイル済みの `ProviderDefinition`、provider が宣言する設定と能力、request の構築を担う prepare 関数を解説します。[AIGateway](../ai-gateway/) の概念ページの上に成り立ちます。ここでは*provider を追加する方法*を扱います。

最も重要な性質を先に述べます。provider module は Elixir 側で request の準備を所有し、Rust の `UniversalAIClient` が wire、つまり transport、encoding、response の正規化を所有します。コンパイルされた定義は、安定した metadata、設定、各能力をどの prepare 関数が所有するかだけを記述します。provider は完全な HTTP client ではなく、prepare 関数と宣言の組み合わせです。

## provider DSL

provider module は `Ankole.AIGateway.ProviderDSL` を使用し、小さな block 構造の DSL で自分自身を宣言します。DSL は metadata と能力の帰属を記録します。request body のフィールドは意図的に記述しません。各 provider の prepare 関数は、同じ module 内の普通の Elixir code です。

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

`provider` block は `ProviderDefinition` struct にコンパイルされ、AIGateway の registry が runtime で使用します。

## コンパイルされた定義

`ProviderDefinition` は次のものを保持します。

| フィールド | 意味 |
|---|---|
| `provider_kind` | 保存された provider row と model binding が使う安定した id |
| `label` | Console 用のローカライズされた表示名 |
| `module` | provider module 自体 |
| `base_url` | 既定の上流 URL（運用者が override 可能） |
| `settings` | 宣言された `Setting` のリスト |
| `capabilities` | 宣言された `Capability` のリスト |

registry は `provider_kind` で provider を解決し、要求された kind に対応する capability を探し、capability の `prepare` 関数を呼び出し、結果を `UniversalAIClient` に渡します。

## 設定

`Setting` は、1 つの運用者オプションまたは request オプションを宣言します。

```elixir
setting(:api_key, encrypted: true, scope: :credential)
setting(:organization, advanced: true)
setting(:reasoningEffort, type: :select, default: "high",
       options: ["minimal", "low", "medium", "high", "xhigh"], scope: :request)
```

| フィールド | 意味 |
|---|---|
| `key` | オプション名（atom） |
| `type` | `:string`、`:select`、`:boolean`、`:map`、または nil |
| `default` | 既定値 |
| `options` | `:select` の場合の許可値 |
| `required?` | 運用者が必ず供給しなければならないか |
| `encrypted?` | 保存時に暗号化される credential 値の storage metadata |
| `advanced?` | Console フォーム用の表示 metadata。validation や runtime は変えない |
| `scope` | `:credential`（pool メンバー単位）、`:connection`（provider row 単位）、または `:request`（model profile 単位） |

すべての provider row は credential pool を持ち、メンバーが 1 つの場合も含みます。resolver は prepare 関数を呼び出す前に、1 つの健全なメンバーを選択し、その `:credential` 設定を復号します。endpoint やカスタムヘッダのような connection 設定は row 全体で共有されます。request 設定は model profile から来ます。prepare 関数は解決後の settings map から 3 つの scope すべてを読み取り、pool の選択は実装しません。

`advanced?` は表示のみです。Console でフィールドを advanced toggle の背後に隠し、validation や動作は変えません。

## 能力

`Capability` は、ユーザーに見える model 能力を prepare 関数と wire の形状に bind します。

```elixir
language_model do
  upstream(:sse)
  api_resolver(:openai_responses)
  prepare(:prepare_language_model)
  supports_parallel_tool_calls()
  supports_native_image_generation()
end
```

| フィールド | 意味 |
|---|---|
| `kind` | `:language_model`、`:embedding_model`、`:rerank_model`、`:web_search`、`:web_fetch`、`:image_generate` のいずれか |
| `upstream` | wire の形状。`:sse`、`:eventstream`、`:websocket_text`、`:json` |
| `api_resolver` | encoding と transport を所有する Rust 側の resolver atom（例: `:openai_responses`） |
| `prepare` | 準備済み request を構築する Elixir 関数 |
| `timeout_ms` | 任意の、能力ごとの timeout |
| `supports_parallel_tool_calls?` | provider が並列 tool 呼び出しを受け付けるか |
| `supports_native_image_generation?` | hosted の `image_generate` profile なしで LLM が公開 image tool を実行できるか |

6 つの capability kind は、runtime が使う外部名にマップします。`language_model` → `"llm"`、`embedding_model` → `"embedding"`、`rerank_model` → `"rerank"` で、3 つの web/image kind は変わりません。LLM だけを提供する provider は `language_model` だけを宣言し、LLM と embedding の両方を提供する provider は両方を宣言します。

## prepare 関数

prepare 関数は provider module 内の普通の Elixir code で、capability の `prepare` フィールドが名前を指定します。`PrepareContext`（解決済みの settings、model request、agent の context）を受け取り、`UniversalAIClient` が送信する準備済み request を返します。

```elixir
def prepare_language_model(%PrepareContext{} = context) do
  %UniversalAIRequest{}
  |> put_url(context.settings.base_url, "/responses")
  |> put_auth("Bearer", context.settings.api_key)
  |> put_body(context.request)
end
```

provider の差異はここにあります。URL の構築、auth ヘッダ、body の整形、特定の上流 API の規則です。prepare 関数が provider の実際の仕事であり、DSL の宣言はその仕事がどう発見され、どう routing されるかを決めます。credential の retry はこの関数の外にあります。control plane が別のメンバーを選択し、request を再構築し、kernel に新しい transport 試行を 1 回実行させられます。

## provider を登録する

ファーストパーティの provider は release にコンパイルされ、registry が発見します。plugin が提供する provider の場合は、Control Plane Plugin の `adapter_declarations/0` で `ai_gateway.provider` contract を通じて宣言します。registry は plugin の宣言からそれを拾い上げます。signal adapter と同じ model で、contract id が異なるだけです。

Plugin の登録は [Skill と Control Plane Plugin の開発](../writing-a-skill/) を参照してください。Provider contract は `ai_gateway.provider` で、kind ID は `~r/\A[a-z][a-z0-9_]{0,62}\z/` に一致しなければなりません。

## このガイドの対象外

これは HTTP client のチュートリアルではありません。prepare 関数が準備済み request を構築し、HTTP を行うのは Rust client です。kernel の transport を迂回する方法でもありません。`api_resolver` と `upstream` の wire 形状は Rust の `UniversalAIClient` が所有するもので、provider は独自の transport を発明するのではなく、既存の resolver から選びます。また、既存の provider を読む代わりにもなりません。`lib/ankole/ai_gateway/providers/` が正規の reference であり、最も単純なもの（OpenAI または openai_compatible）が正しい出発点です。

## 次のステップ

- AIGateway の概念（routing、resolution、統一 boundary）については、[AIGateway](../ai-gateway/) をお読みください。
- Plugin の登録については、[Skill と Control Plane Plugin の開発](../writing-a-skill/) をお読みください。
- 最初の Provider のセットアップについては、[クイックスタート](../quickstart/#3-add-an-llm-provider-and-create-an-agent) をお読みください。