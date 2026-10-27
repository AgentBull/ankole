---
title: Rust Kernel
description: Elixir Control Plane から Rustler 経由で読み込まれるネイティブ機能および AI 通信ライブラリについて説明します。
section: Developer guide
order: 109
---

Rust Kernel は Control Plane 向けのネイティブライブラリです。Elixir からは Rustler 経由で読み込まれ、Bun Worker 側では生成済みの protobuf コーデックを利用して通信します。

## ネイティブ機能

`app/kernel/src` では、次の機能を提供しています。

- **`common/`**：AEAD 暗号化・復号、鍵導出、エンコード、ハッシュ計算、UUIDv7 識別子生成、JWT ヘルパー、電話番号の正規化、Reciprocal Rank Fusion、トークン数の見積もり、および URL・IP に対する SSRF 検証を行います。
- **`authz/`**：明示的なスナップショットにもとづく権限評価、CEL 式の検証と条件評価、リソースパターンの照合を行います。評価に必要なデータは、[Principal と AuthZ](../principal-authz/) で解説されているとおり Control Plane から渡されます。
- **`universal_ai_client/`**：上流 Provider との HTTP SSE / EventStream および WebSocket 通信、レスポンスの正規化、下流向け JSON テキストチャンクのエンコード、デマンドクレジット制御、キャンセル処理、タイムアウト管理を担います。
- **`object_store/`**：ローカルディレクトリまたは S3 互換バケットをバックエンドとするファイルサービスのストレージ層を提供します。
- **`page_document/`**：Pod ページの XML ツリー検証、Wordgard 変更セットの適用、および UTF-16 差分の計算を行います。
- **`brain_markdoc/`** と **`markdown.rs`**：Brain ドキュメント本文の解析と Markdown のパースを行います。
- **`model_image.rs`**：モデル向け画像のデコード、リサイズ、フォーマット変換を行います。
- **`web_proxy.rs`**：Worker 上の Chromium セッション向けに、名前解決後のアドレスに対して SSRF 検査を実施するループバック SOCKS5 `CONNECT` プロキシを提供します。
- **`signals/`**：渡されたコンテキストにもとづいてルーティングポリシーを評価します。

## 所有権

永続状態の管理、権限データ、Provider の選択、認証情報、ドメイン状態のコミットはすべて Control Plane が所有します。これに対し、Rust Kernel は準備済みの入力データを受け取って処理するだけであり、PostgreSQL への直接クエリや Agent のスケジューリング、Worker ソケットの保持は行いません。また、プログラムによるツール呼び出し（PTC）や Pod Applet バックエンド関数における分離された TypeScript 実行は、Rust Kernel ではなくステートレスな `ankole-function-runtime` サービスが担当します。

RuntimeFabric のエンベロープ構造とプロトコルバージョン 10 は、`app/kernel/proto/ankole/runtime_fabric/v1/envelope.proto` で宣言されています。シリアライズには Elixir 側で Protox、Worker 側で protobuf-es を使用し、双方が送信時に宣言されたバージョンを設定して受信時に検証します。実行権限の確認は各ドメインの受信側で行い、言語間のコーデック互換性は golden fixture で検証しています。

## ビルドと通信

Cargo フィーチャーの `nif` は `src/nif_exports.rs` を通じて Elixir Control Plane 向けに提供され、`napi` は `src/napi_exports.rs` を通じて Worker のブラウザデーモンおよびホストテスト向けに提供されます。`src/nif_exports.rs` では Rustler を使って BEAM の値とエラーを変換しますが、JSON 形式の値とバイト列はこの境界を越えてもそれぞれの表現をそのまま保ちます。

共有の reqwest クライアントは、すべての環境で HTTP/1.1 と aws-lc-rs TLS を使用します。一方、上流への WebSocket 呼び出しには別の接続を使用します。Provider ポリシーの管理とトランスクリプトのコミットは [AIGateway](../ai-gateway/) が所有します。

Worker のライフサイクル管理とメッセージルーティングについては、[Sessions](../sessions/) および [Agent Computer Worker](../agent-computer-worker/) を参照してください。
