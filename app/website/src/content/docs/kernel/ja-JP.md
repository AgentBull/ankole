---
title: Rust Kernel
description: Elixir Control Plane が Rustler を通じて読み込むネイティブ機能と AI 通信ライブラリ。
section: Developer guide
order: 109
---

Rust Kernel は Control Plane のネイティブライブラリです。Elixir が Rustler を通じて読み込みます。Bun Worker は生成された protobuf コーデックを使います。

## ネイティブ機能

`app/kernel/src` は次の機能を提供します。

- **`common/`**：AEAD 暗号処理、鍵導出、エンコード、ハッシュ、UUIDv7 識別子、JWT ヘルパー、電話番号の正規化、Reciprocal Rank Fusion、トークン見積もり、URL/IP の SSRF 検証。
- **`authz/`**：明示的なスナップショットに基づく権限評価、CEL 検証と条件評価、リソースパターン照合。Control Plane は [Principal と AuthZ](../principal-authz/) で説明するデータを渡します。
- **`universal_ai_client/`**：上流の HTTP SSE/EventStream と WebSocket 通信、応答の正規化、下流 JSON テキストチャンクのエンコード、需要クレジット、キャンセル、タイムアウト。
- **`object_store/`**：ローカルディレクトリまたは S3 互換バケットを使うファイルサービスのストレージ。
- **`page_document/`**：Pod ページ XML ツリーの検証、Wordgard 変更セットの適用、UTF-16 差分計算。
- **`brain_markdoc/`** と **`markdown.rs`**：Brain 本文の解析と Markdown のパース。
- **`model_image.rs`**：モデル画像のデコード、リサイズ、変換。
- **`web_proxy.rs`**：Worker の Chromium セッション向けに解決済みアドレスの SSRF 検査を行うループバック SOCKS5 `CONNECT` プロキシ。
- **`signals/`**：渡されたコンテキストに基づくルーティングポリシーの評価。

## 所有権

Control Plane は永続状態、権限データ、プロバイダー選択、認証情報、ドメインのコミットを所有します。Kernel は準備済みの入力を受け取り、PostgreSQL の照会、Agent のスケジュール、Worker socket の所有は行いません。プログラムによるツール呼び出し（PTC）や Pod Applet バックエンド関数の分離された TypeScript 実行は、Rust Kernel ではなくステートレスな `ankole-function-runtime` サービスで行われます。

RuntimeFabric の構造とプロトコルバージョン 10 は `app/kernel/proto/ankole/runtime_fabric/v1/envelope.proto` で宣言します。Elixir は Protox、Worker は protobuf-es を使います。両側で送信時に宣言されたバージョンを設定し、受信時に確認します。ドメインの受信側が実行権限を確認し、言語間の golden fixture がコーデックの一致を検証します。

## ビルドと通信

Cargo feature `nif` は `src/nif_exports.rs` を通じて Elixir Control Plane 向けに、`napi` は `src/napi_exports.rs` を通じて Worker のブラウザデーモンとホストテスト向けに提供されます。Rustler は `src/nif_exports.rs` で BEAM の値とエラーを変換します。JSON 形式の値とバイトデータは、この境界でそれぞれの表現を保持します。

共有 reqwest client は各環境で HTTP/1.1 と aws-lc-rs TLS を使います。上流の WebSocket 呼び出しには別の接続を使います。プロバイダーポリシーと transcript のコミットは [AIGateway](../ai-gateway/) が所有します。

Worker のライフサイクルとメッセージルーティングは [Sessions](../sessions/) と [Agent Computer Worker](../agent-computer-worker/) を参照してください。
