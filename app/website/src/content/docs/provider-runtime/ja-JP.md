---
title: Provider ランタイム
description: AIGateway が selector を provider に解決し、準備済みリクエストを構築し、kernel を通じてディスパッチする仕組み — モデル呼び出しから provider 応答までの 3 つの段階。
section: Developer guide
order: 119
---

モデル呼び出しは provider に到達するまでに 3 つの段階を通過します。resolver が selector を provider ランタイムマップに変換し、provider モジュールが準備済みリクエストを構築し、kernel の `UniversalAIClient` がそれを実行します。このページは、`ai_gateway/resolver.ex`、`providers.ex`、`universal_ai_request.ex` の実際のコードに照らしてこのパスを説明します。[AIGateway](../ai-gateway/)と[provider の追加](../adding-a-provider/)の上に構築されています。

resolver、provider モジュール、kernel はそれぞれ 1 つの段階を所有します。resolver は selector、credential プールの選択、OAuth refresh を所有します。provider モジュールはリクエスト準備を所有します。kernel は 1 回のワイヤー試行を所有します。control-plane の試行所有者は別の credential を選択してリクエストを再構築できますが、kernel は自分で credential を選択したり再試行したりすることはありません。

## 段階 1: 解決（Resolver）

`Ankole.AIGateway.Resolver` は、リクエストの `model` フィールドを具体的な provider ランタイムマップに変換します。ここで、`primary`、`web_search.default`、明示的な `provider_id/model` などの subject に見える selector が、provider id、provider kind、上流のモデル名、解決済みのランタイム設定になります。

Agent には 8 つの組み込みモデルプロファイルがあります。`primary`、`light`、`heavy`、`coding`、`vision_fallback`、`web_search`、`web_fetch`、`image_generate` です。`coding` は、ユーザー向けの Background Agent Jobs プロファイルが API と保存時に使う名前です。最初の 5 つは言語モデルを選択し、最後の 3 つは web 検索、web fetch、画像生成の各能力を選択します。

Embedding と rerank は Agent プロファイルではありません。これらの能力を AIGateway から直接呼び出す場合は、明示的な `provider_id/model` selector が必要です。Brain は、[AppConfigure](../app-configuration/) の `brain.embedding_model` と `brain.rerank_model` からインスタンス共通のモデルを読み取ります。検索への影響については [Brain](../brain/) を参照してください。

provider 行を解決した後、resolver は使用可能な credential を 1 つ選択します。thread affinity は、その行の `fill_first`、`round_robin`、`least_used`、`random` 戦略より優先されます。ランタイムマップは正確な credential ID を後続のすべての失敗パスに運びます。ChatGPT サブスクリプションの OAuth メンバーについては、resolver は provider 行のロック下で、有効期限が近いか古い token を refresh します。永続的な refresh 失敗はそのメンバーを `dead` にし、一時的な失敗は `exhausted` にします。どちらも次の使用可能なメンバーを選択します。

解決は、どの provider にも接触する前に失敗することがあります。

- `422 unknown_model_selector` — selector がこの subject にバインドされていない。
- `422 model_binding_not_configured` — capability と名前はバインドされているが、provider 行が不完全。

これらのエラーは、欠落したモデルプロファイル、利用できない Provider、または不完全な Provider 構成を特定します。

利用できない credential プールは別物です。それは現在の各メンバーの安全なステータスとともに `credential_pool_exhausted` を返します。現在 `exhausted` のメンバーに既知の将来のリカバリ時刻がある場合にのみ、`retry_at` を含みます。

## 段階 2: 準備（Provider モジュール + Providers）

ランタイムマップが解決されたら、`Ankole.AIGateway.Providers` が provider モジュールの prepare 関数にディスパッチします。エントリポイントは capability によって型付けされています。

```elixir
build_response_request(runtime, request)    # :language_model
build_embeddings_request(runtime, request)  # :embedding_model
build_rerank_request(runtime, request)      # :rerank_model
build_web_search_request(runtime, request)  # :web_search
build_web_fetch_request(runtime, request)   # :web_fetch
build_image_generate_request(runtime, request) # :image_generate
```

それぞれが `build_prepared_request/4` に委譲します。これは provider の `ProviderDefinition` 上の capability を調べ、provider がそれをサポートすることを検証し（`supports_capability?/2`）、capability の `prepare` 関数を呼び出します。これは、解決された設定とリクエストから `UniversalAIRequest` 構造体を構築する通常の Elixir 関数です。準備済みリクエストは、選択された credential ID を持つ control-plane 専用の再構築コンテキストを保持します。このコンテキストは、リクエストがネイティブ境界を越える前に取り除かれます。

provider の違いが存在するのはこの段階です。URL の構築、auth ヘッダー、ボディの成形、特定の上流 API の癖です。準備済みリクエストは `UniversalAIRequest` — path、`api_resolver` atom、ヘッダー、provider オプションを持つ構造体 — であり、HTTP 呼び出しではありません。

## 段階 3: 実行（UniversalAIRequest → kernel）

`UniversalAIRequest` は、AIGateway から kernel の `UniversalAIClient` への薄い実行アダプターです。provider モジュールはリクエスト仕様を準備し、アダプターがそれを実行して、Phoenix 呼び出し元が期待する HTTP/SSE-ready 境界を維持します。

実行は準備済みリクエストを Rust kernel に渡し、kernel は次のことを行います。

- `api_resolver` をワイヤープロトコル（エンコーディング、トランスポート）に解決する
- 上流の接続を開く（capability の `upstream` が宣言したとおり、HTTP SSE、EventStream、WebSocket、またはプレーンな JSON）
- provider の auth とヘッダーでリクエストを送信する
- 応答ストリームを受け取る
- ダウンストリームのチャンク形式に正規化する

kernel は成功と失敗の両方で、制限された応答ヘッダーセットを返します。`x-codex-*` レート制限系ヘッダーと `cf-mitigated` を含みますが、credential、cookie、その他の provider ヘッダーは除外します。control plane はこのセットをクールダウン、レート制限の投影、Cloudflare challenge の診断に使います。

`CredentialAttempts` は各 kernel 試行を包みます。帰属できる `429`、`5xx`、またはトランスポート失敗は、その試行を行った credential だけをマークし、別の健全なメンバーを選択し、認可と provider ヘッダーを再構築し、指数バックオフとジッターで待ち、kernel に新しい試行を 1 回依頼します。使用可能なメンバーが 1 つだけの場合は、同じ credential で 1 回再試行します。credential ID のない失敗はどのメンバーもマークせず、プールを 1 周した後に停止します。すべてのメンバーが利用できない場合、試行所有者は `credential_pool_exhausted` を返します。別の provider に切り替えることはありません。

これが [Kernel](../kernel/)ページが文書化する段階です。Rust の `universal_ai_client` モジュールと、そのトランスポート、demand credit、キャンセルです。provider モジュールは実行に参加しません。

## 失敗がどのように表面化するか

各段階は異なるクラスのエラーを生成します。

| 段階 | 失敗の形状 | 意味 |
|---|---|---|
| 解決 | `422 unknown_model_selector` / `model_binding_not_configured` | selector または binding が間違っている — 設定の問題であり、一時的ではない |
| Credential プール | `429 credential_pool_exhausted` | すべてのメンバーが無効、dead、またはクールダウン中。`retry_at` があれば待ち、なければプールを修復する |
| 準備 | `422 unsupported_capability` / provider 固有の検証 | provider がこの capability を提供していないか、リクエストオプションが無効 |
| 実行 | `502 upstream_response_failed` / `504 upstream_timeout` | provider がエラーを返したかタイムアウトした — 一時的かもしれない |

エラークラスは、呼び出し元に設定を修正するのか（422）、待って再試行するのか（502/504）、provider を調査するのかを伝えます。[AIGateway](../ai-gateway/)ページが完全なエラーエンベロープを文書化しています。

## レジストリとプラグインが提供する provider

`Providers` の provider レジストリは、コンパイル済みの `ProviderDefinition` 構造体を保持します。ファーストパーティの provider はコンパイル時に組み込まれ、プラグインが提供する provider は `ai_gateway.provider` コントラクトを通じて到着し、`refresh_from_adapter_declarations/1` がそれらをレジストリにマージします。provider kind は `~r/\A[a-z][a-z0-9_]{0,62}\z/` に一致しなければならず、レジストリはマージ済みセットをキャッシュするため、解決は呼び出しのたびにプラグインを再スキャンしません。

## このガイドがそうでないもの

provider 作成のチュートリアルではありません。DSL、定義、prepare 関数は[provider の追加](../adding-a-provider/)を参照してください。ワイヤープロトコルのリファレンスでもありません。kernel がワイヤーを所有し、それは [Kernel](../kernel/)ページです。そして、3 つのモジュールを読むことの代替でもありません。このページはそれらを通るパスです。

## 次のステップ

- provider の書き方については、[provider の追加](../adding-a-provider/)を参照してください。
- AIGateway のコンセプトページ（エンドポイント、エラーの形状）については、[AIGateway](../ai-gateway/)を参照してください。
- リクエストを実行する kernel については、[Kernel](../kernel/)を参照してください。
- 最初のモデルプロファイルのセットアップについては、[Quick start](../quickstart/#llm-providers)を参照してください。
