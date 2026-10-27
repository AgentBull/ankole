---
title: Provider ランタイム
description: AIGateway がセレクターから Provider を解決し、準備済みリクエストを組み立てて Kernel 経由で送信するまでの 3 段階の処理フローを説明します。
section: Developer guide
order: 119
---

モデル呼び出しが上流の Provider に届くまでには、3 つの段階を通ります。まず Resolver がセレクターを Provider のランタイムマップへ変換し、次に各 Provider モジュールが準備済みリクエスト（prepared request）を組み立て、最後に Rust Kernel の `UniversalAIClient` が通信を実行します。このページでは、`ai_gateway/resolver.ex`、`providers.ex`、`universal_ai_request.ex` の実装に沿ってこの一連の経路を解説します。前提となる設計については、[AIGateway](../ai-gateway/) および [provider の追加](../adding-a-provider/) をあわせて参照してください。

Resolver、Provider モジュール、Kernel は、それぞれ明確に 1 つの段階だけを担当します。Resolver はセレクター解決、認証情報プールの選択、OAuth トークンのリフレッシュを担います。Provider モジュールはリクエストの組み立てを担います。そして Kernel は 1 回分の通信試行（ワイヤ試行）を担います。コントロールプレーン側の試行管理層が別の認証情報を選び直してリクエストを再構築することはありますが、Kernel 自身が勝手に認証情報を切り替えたりリトライしたりすることはありません。

## 段階 1: 解決（Resolver）

`Ankole.AIGateway.Resolver` は、リクエストの `model` フィールドを具体的な Provider ランタイムマップへ変換します。この段階で、`primary` や `web_search.default`、あるいは明示的な `provider_id/model` といった呼び出し元（subject）向けのセレクターが、実際の Provider ID、Provider 種別（kind）、上流モデル名、および解決済みのランタイム設定へと展開されます。

Agent には 8 種類の組み込みモデルプロファイル（`primary`、`light`、`heavy`、`coding`、`vision_fallback`、`web_search`、`web_fetch`、`image_generate`）があります。このうち `coding` は、管理画面上の Background Agent Jobs プロファイルが API や永続化層で使用する内部名です。先頭の 5 つは言語モデルを選択し、残りの 3 つはそれぞれ Web 検索、Web フェッチ、画像生成の各機能（capability）を選択します。

なお、Embedding と Rerank は Agent プロファイルには含まれません。これらを AIGateway から直接呼び出す際は、明示的な `provider_id/model` セレクターを指定する必要があります。Brain では、[AppConfigure](../app-configuration/) の `brain.embedding_model` からサイト単位の Embedding モデルを、`brain.rerank_model` からテナント単位の Rerank モデルを読み取ります。検索精度や挙動への影響については [Brain](../brain/) を参照してください。

対象の Provider レコードを特定すると、Resolver は利用可能な認証情報（credential）を 1 つ選択します。その際、スレッドアフィニティ（thread affinity）がある場合は、レコードに設定された `fill_first`、`round_robin`、`least_used`、`random` といった選択戦略よりも優先されます。選択された credential ID はランタイムマップに格納され、後続のすべての失敗処理経路へそのまま引き継がれます。また、ChatGPT Subscription の OAuth プールメンバーについては、Provider レコードのロックを取得した状態で、有効期限切れまたは期限間近のトークンをリフレッシュします。リフレッシュで恒久的な失敗が発生した場合はそのメンバーを `dead`、一時的な失敗の場合は `exhausted` に更新し、いずれの場合も次の利用可能なメンバーを選び直します。

なお、上流 Provider への通信を始める前の解決段階でエラーが返ることもあります。

- `422 unknown_model_selector`：指定されたセレクターがこの subject にバインドされていません。
- `422 model_binding_not_configured`：機能名とプロファイル名はバインドされているものの、参照先の Provider レコードの設定が不完全です。

これらのエラーからは、モデルプロファイルの未設定、Provider の利用不可、または Provider 設定の不足を特定できます。

一方、認証情報プール内に使えるメンバーが残っていないケースは別のエラーとして扱われ、各メンバーの安全な状態情報とともに `credential_pool_exhausted` が返されます。現在 `exhausted` 状態のメンバーに既知の復旧予定時刻がある場合にのみ、`retry_at` フィールドが付与されます。

## 段階 2: 準備（Provider モジュール + Providers）

ランタイムマップが解決されると、`Ankole.AIGateway.Providers` が該当する Provider モジュールの prepare 関数へ処理を振り分けます。エントリポイントは機能（capability）ごとに型付けされています。

```elixir
build_response_request(runtime, request)    # :language_model
build_embeddings_request(runtime, request)  # :embedding_model
build_rerank_request(runtime, request)      # :rerank_model
build_web_search_request(runtime, request)  # :web_search
build_web_fetch_request(runtime, request)   # :web_fetch
build_image_generate_request(runtime, request) # :image_generate
```

これらの関数はすべて内部で `build_prepared_request/4` に委譲します。`build_prepared_request/4` は対象 Provider の `ProviderDefinition` から該当 capability を探し、サポート有無を検証（`supports_capability?/2`）したうえで、その capability の `prepare` 関数を呼び出します。`prepare` 関数は、解決済みの設定と入力リクエストから `UniversalAIRequest` 構造体を組み立てる純粋な Elixir 関数です。組み立てられたリクエストには選択済みの credential ID を含むコントロールプレーン専用の再構築コンテキストが付随しますが、このコンテキストはネイティブ（Rust Kernel）境界へ渡す直前に除去されます。

URL の組み立て、認証ヘッダーの付与、リクエストボディの整形、上流 API ごとの細かい仕様差分の吸収はすべてこの段階に集約されます。ここで生成される `UniversalAIRequest` は、パス、`api_resolver` アトム、ヘッダー、Provider オプションを保持するデータ構造体であり、この時点ではまだ HTTP 通信は発生しません。

## 段階 3: 実行（UniversalAIRequest → kernel）

`UniversalAIRequest` は、AIGateway から Rust Kernel の `UniversalAIClient` を呼び出すための薄い実行アダプターでもあります。Provider モジュールがリクエスト仕様を組み立て、このアダプターが実行を引き受けることで、Phoenix 側の呼び出し元が期待する HTTP/SSE ストリーミング境界を保ちます。

準備済みリクエストを受け取った Rust Kernel は、次の処理を順に実行します。

- `api_resolver` からワイヤプロトコル（エンコーディング方式とトランスポート）を決定する
- capability の `upstream` 宣言に従い、上流への接続（HTTP SSE、EventStream、WebSocket、または通常の JSON HTTP）を開く
- Provider 向けの認証情報とヘッダーを付与してリクエストを送信する
- レスポンスストリームを受信する
- 下流向けの共通チャンク形式へ正規化する

Kernel は成功時・失敗時の双方において、厳選されたレスポンスヘッダーのみをコントロールプレーンへ返します。ここには `x-codex-*` 系のレート制限ヘッダーや `cf-mitigated` が含まれますが、認証情報や Cookie、その他の不要な Provider ヘッダーは除外されます。コントロールプレーンはこのヘッダー情報を使って、クールダウン制御、レート制限状態の投影、および Cloudflare チャレンジ発生時の診断を行います。

各 Kernel 試行の外側は `CredentialAttempts` がラップしています。特定の認証情報に起因する `429`、`5xx`、またはトランスポートエラーが発生した場合、`CredentialAttempts` はその試行で使った認証情報だけを記録し、別の健全なプールメンバーを選び直して認可ヘッダーと Provider ヘッダーを再構築し、ジッター付きの指数バックオフで待機した後に Kernel へ再試行を依頼します。利用可能なメンバーが 1 つしかない場合は、同じ認証情報で 1 回だけ再試行します。一方、credential ID に紐付かない失敗ではどのメンバーの状態も変更せず、プールを一巡した時点で停止します。すべてのメンバーが利用不能になった場合は、別の Provider へ勝手にフォールバックすることなく `credential_pool_exhausted` を返します。

この通信層の内部構造——Rust の `universal_ai_client` モジュールによるトランスポート処理、デマンドクレジット制御、キャンセル処理——については [Kernel](../kernel/) ページで詳しく解説しています。Provider モジュール側はこの実行フェーズには一切関与しません。

## 失敗がどのように表面化するか

エラーが発生した段階ごとに、返されるステータスコードとエラー種別が明確に分かれています。

| 段階 | 失敗の形状 | 意味 |
|---|---|---|
| 解決 | `422 unknown_model_selector` / `model_binding_not_configured` | セレクターまたはバインディングの不備です。一時的な障害ではなく設定の問題を示します |
| Credential プール | `429 credential_pool_exhausted` | すべてのプールメンバーが無効、`dead`、またはクールダウン中です。`retry_at` があれば待機し、なければプール設定を修復します |
| 準備 | `422 unsupported_capability` / Provider 固有の検証エラー | 対象 Provider がその機能を提供していないか、指定されたリクエストオプションが無効です |
| 実行 | `502 upstream_response_failed` / `504 upstream_timeout` | 上流 Provider がエラーを返したかタイムアウトしました。一時的な障害の可能性があります |

呼び出し元はこのエラー分類を見ることで、設定を修正すべきか（422）、少し待って再試行すべきか（502/504）、あるいは上流 Provider の障害を調査すべきかを即座に判断できます。エラーエンベロープ全体の仕様については、[AIGateway](../ai-gateway/) を参照してください。

## レジストリとプラグインが提供する provider

`Providers` 内の Provider レジストリは、コンパイル済みの `ProviderDefinition` 構造体を保持しています。ファーストパーティ製の Provider はコンパイル時に組み込まれ、プラグイン由来の Provider は `ai_gateway.provider` コントラクトを通じて登録され、`refresh_from_adapter_declarations/1` によってレジストリへマージされます。Provider の kind 名は正規表現 `~r/\A[a-z][a-z0-9_]{0,62}\z/` に一致する必要があり、マージ後の定義セットはレジストリにキャッシュされるため、リクエスト解決のたびにプラグインを再スキャンするオーバーヘッドは発生しません。

## このガイドがそうでないもの

このページは新しい Provider を実装するための手順書ではありません。DSL や定義方法、`prepare` 関数の書き方については [provider の追加](../adding-a-provider/) を参照してください。また、ワイヤプロトコルの詳細リファレンスでもありません。通信層の実装については [Kernel](../kernel/) を参照してください。このページは、実装コードの 3 つのモジュールを横断する処理の流れを俯瞰するためのガイドです。

## 次のステップ

- 新しい Provider の実装方法については、[provider の追加](../adding-a-provider/) を参照してください。
- エンドポイントやエラー形式など AIGateway の全体像については、[AIGateway](../ai-gateway/) を参照してください。
- リクエストを実行する Rust Kernel の仕組みについては、[Kernel](../kernel/) を参照してください。
- 最初のモデルプロファイルを登録する手順については、[Quick start](../quickstart/#llm-providers) を参照してください。
