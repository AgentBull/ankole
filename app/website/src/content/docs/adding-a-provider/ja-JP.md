---
title: Provider の追加
description: AIGateway provider の宣言方法。DSL、コンパイルされた定義、設定、能力、prepare 関数、plugin ベースの登録について説明します。
section: Developer guide
order: 115
---

AIGateway provider は、Ankole が上流の AI サービス（LLM、embedding モデル、Web 検索 API など）と通信するための仕組みです。このページはコントリビューター向けのウォークスルーであり、[AIGateway](../ai-gateway/) の概念ページを前提に、*実際に provider を追加する手順*を解説します。具体的には、provider DSL、そこからコンパイルされる `ProviderDefinition`、設定項目や capability の宣言方法、そしてリクエストの組み立てを担う prepare 関数について説明します。

まず押さえておくべき最も重要な設計原則があります。Elixir 側の provider モジュールはリクエストの準備だけを担当し、通信経路（transport、エンコーディング、レスポンスの正規化）はすべて Rust 側の `UniversalAIClient` が担当します。コンパイル済みの定義に記述されるのは、不変のメタデータ、設定項目、そして各 capability をどの prepare 関数で処理するかという対応付けだけです。つまり provider とは完全な HTTP クライアントではなく、宣言と prepare 関数の組み合わせにすぎません。

## provider DSL

provider モジュールでは `Ankole.AIGateway.ProviderDSL` を使い、簡潔なブロック構造の DSL で provider を宣言します。DSL に記述するのはメタデータと capability の紐付けのみであり、リクエストボディのフィールド構造まではあえて記述しません。各 provider の prepare 関数は、同じモジュール内に通常の Elixir コードとして実装します。

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

`provider` ブロックはコンパイル時に `ProviderDefinition` 構造体へ変換され、実行時に AIGateway のレジストリから参照されます。

## コンパイルされた定義

`ProviderDefinition` には次のフィールドが含まれます。

| フィールド | 意味 |
|---|---|
| `provider_kind` | 保存された provider レコードおよび model binding で使われる不変の識別子 |
| `label` | Console に表示するローカライズ済みの名称 |
| `module` | provider モジュール自体 |
| `base_url` | 既定の上流 URL（運用者が上書き可能） |
| `settings` | 宣言された `Setting` のリスト |
| `capabilities` | 宣言された `Capability` のリスト |

リクエスト実行時には、レジストリが `provider_kind` から対象の provider を引き当て、要求された種別に対応する capability を探します。そのうえで capability に指定された `prepare` 関数を呼び出し、返された結果を `UniversalAIClient` に渡します。

## 設定

`Setting` は、運用者向けの設定項目またはリクエスト単位のオプションを 1 つ宣言します。

```elixir
setting(:api_key, encrypted: true, scope: :credential)
setting(:organization, advanced: true)
setting(:reasoningEffort, type: :select, default: "high",
       options: ["minimal", "low", "medium", "high", "xhigh"], scope: :request)
```

| フィールド | 意味 |
|---|---|
| `key` | オプション名（atom） |
| `type` | `:string`、`:select`、`:boolean`、`:map`、または `nil` |
| `default` | 既定値 |
| `options` | `:select` の場合に許可される値のリスト |
| `required?` | 運用者による指定を必須にするかどうか |
| `encrypted?` | 認証情報を保存時に暗号化するためのストレージ用メタデータ |
| `advanced?` | Console フォームの表示制御用メタデータ。バリデーションや実行時の挙動には影響しない |
| `scope` | `:credential`（pool メンバー単位）、`:connection`（provider レコード単位）、または `:request`（model profile 単位） |

すべての provider レコードは、メンバーが 1 つだけの場合も含めて credential pool を持ちます。resolver は prepare 関数を呼び出す前に正常なメンバーを 1 つ選び、その `:credential` 設定を復号します。一方、エンドポイントやカスタムヘッダーなどの `:connection` 設定は provider レコード全体で共有され、`:request` 設定は model profile から渡されます。prepare 関数は解決済みの settings マップからこれら 3 つのスコープの値をまとめて読み取るだけでよく、pool メンバーの選択ロジックを実装する必要はありません。

なお、`advanced?` は画面表示専用のフラグです。Console 上で入力欄を詳細設定トグルの中に折りたたむだけで、バリデーションや実行時の挙動は変わりません。

## 能力

`Capability` は、ユーザーに公開されるモデルの機能を prepare 関数および通信フォーマットに結び付けます。

```elixir
language_model do
  api_resolver(:openai_responses)
  prepare(:prepare_language_model)
  supports_parallel_tool_calls()
  supports_native_image_generation()
end
```

| フィールド | 意味 |
|---|---|
| `kind` | `:language_model`、`:embedding_model`、`:rerank_model`、`:web_search`、`:web_fetch`、`:image_generate` のいずれか |
| `upstream` | 通信フォーマット。`kind` から自動的に決まり、`:language_model` は `:sse`、それ以外はすべて `:json` になる |
| `api_resolver` | エンコーディングと transport を担う Rust 側の resolver atom（例: `:openai_responses`） |
| `prepare` | 送信用のリクエストを組み立てる Elixir 関数 |
| `timeout_ms` | capability 単位のタイムアウト（任意） |
| `supports_parallel_tool_calls?` | provider が並列ツール呼び出しを受け付けるかどうか |
| `supports_native_image_generation?` | hosted の `image_generate` プロファイルなしで、LLM が公開画像ツールを実行できるかどうか |

これら 6 種類の capability kind は、実行時に使われる外部名へマッピングされます。具体的には `language_model` が `"llm"`、`embedding_model` が `"embedding"`、`rerank_model` が `"rerank"` に対応し、残りの 3 つの Web / 画像系 kind はそのままの名前で使われます。LLM のみを提供する provider は `language_model` だけを宣言し、LLM と embedding の両方を提供する provider はその両方を宣言します。

## prepare 関数

prepare 関数は provider モジュール内に定義する通常の Elixir 関数で、関数名は capability の `prepare` フィールドで指定します。引数として `PrepareContext`（解決済みの settings、モデルリクエスト、Agent のコンテキスト）を受け取り、`UniversalAIClient` が送信可能な形式のリクエストを返します。

```elixir
def prepare_language_model(%PrepareContext{} = context) do
  %UniversalAIRequest{}
  |> put_url(context.settings.base_url, "/responses")
  |> put_auth("Bearer", context.settings.api_key)
  |> put_body(context.request)
end
```

URL の組み立て、認証ヘッダーの付与、リクエストボディの整形など、上流 API ごとの仕様の違いはすべてこの関数で吸収します。つまり provider 固有の実処理は prepare 関数に集約されており、DSL の宣言はその関数をどのように検出しルーティングするかを定義します。なお、認証情報の切り替えを伴うリトライ処理はこの関数の外で行われます。リトライが必要な場合、control plane がプール内の別メンバーを選び直してリクエストを再構築し、kernel に新しい通信試行を 1 回実行させます。

## provider を登録する

ファーストパーティの provider はリリースビルドにコンパイルされ、レジストリによって自動的に検出されます。プラグインから provider を提供する場合は、Control Plane Plugin の `adapter_declarations/0` において `ai_gateway.provider` コントラクトを使って宣言します。すると、レジストリがプラグインの宣言からその provider を取り込みます。仕組み自体は signal adapter と同じで、コントラクト ID が異なるだけです。

プラグインの登録方法については、[Skill と Control Plane Plugin の開発](../writing-a-skill/) を参照してください。provider のコントラクト名は `ai_gateway.provider` であり、kind ID は正規表現 `~r/\A[a-z][a-z0-9_]{0,62}\z/` に一致する必要があります。

## このガイドの対象外

このガイドは HTTP クライアントの実装チュートリアルではありません。prepare 関数が行うのはリクエストデータの組み立てまでであり、実際の HTTP 通信は Rust クライアントが実行します。また、kernel の通信層をバイパスする方法を説明するものでもありません。`api_resolver` や `upstream` の通信フォーマットは Rust 側の `UniversalAIClient` が管理するため、各 provider は独自の通信処理を実装するのではなく、既存の resolver から適切なものを選択します。さらに、実装にあたっては既存の provider コードも必ず確認してください。`lib/ankole/ai_gateway/providers/` が正式なリファレンス実装であり、まずは最もシンプルな OpenAI または `openai_compatible` のコードから読み始めるのがおすすめです。

## 次のステップ

- AIGateway の基本概念（ルーティング、プロファイル解決、統一境界）については、[AIGateway](../ai-gateway/) を参照してください。
- プラグインの登録手順については、[Skill と Control Plane Plugin の開発](../writing-a-skill/) を参照してください。
- 最初の Provider をセットアップする手順については、[クイックスタート](../quickstart/#llm-providers) を参照してください。
