---
title: Rust Kernel
description: Elixir Control Plane が Rustler を通じて読み込むネイティブ機能と AI 通信ライブラリ。
section: Developer guide
order: 109
---

Rust Kernel は Control Plane のネイティブライブラリです。Elixir が Rustler を通じて読み込みます。Bun Worker は生成された protobuf コーデックを使い、Kernel のネイティブモジュールを読み込みません。

## ネイティブ機能

`app/kernel` は次の機能を提供します。

- **`common/`**：暗号処理、鍵導出、パスワードハッシュ、エンコード、UUIDv7 識別子、JWT ヘルパー、電話番号の正規化。
- **`authz/`**：明示的なスナップショットに基づく権限評価、CEL 検証、リソースパターン照合。Control Plane は [Principal と AuthZ](../principal-authz/) で説明するデータを渡します。
- **`universal_ai_client/`**：上流の HTTP SSE/EventStream と WebSocket 通信、応答の正規化、下流 JSON テキストチャンクのエンコード、需要クレジット、キャンセル、タイムアウト。
- **`object_store/`**：ローカルディレクトリまたは S3 互換バケットを使うファイルサービスのストレージ。
- **`program_runner/`**、**`brain_markdoc/`**、**`model_image/`**：プログラムによるツール実行、Brain 本文の解析、モデル画像の変換。
- **`signals/`**：渡されたコンテキストに基づくルーティングポリシーの評価。

## 所有権

Control Plane は永続状態、権限データ、プロバイダー選択、認証情報、ドメインのコミットを所有します。Kernel は準備済みの入力を受け取り、PostgreSQL の照会、Agent のスケジュール、Worker socket の所有は行いません。

RuntimeFabric の構造とプロトコルバージョン 10 は `proto/ankole/runtime_fabric/v1/envelope.proto` で宣言します。Elixir は Protox、Worker は protobuf-es を使います。両側で送信時に宣言されたバージョンを設定し、受信時に確認します。ドメインの受信側が実行権限を確認し、言語間の golden fixture がコーデックの一致を検証します。

## ビルドと通信

開発、テスト、本番で Cargo feature `nif` を共用します。Rustler は `src/nif_exports.rs` で BEAM の値とエラーを変換します。JSON 形式の値とバイトデータは、この境界でそれぞれの表現を保持します。

共有 reqwest client は各環境で HTTP/1.1 と aws-lc-rs TLS を使います。上流の WebSocket 呼び出しには別の接続を使います。プロバイダーポリシーと transcript のコミットは [AIGateway](../ai-gateway/) が所有します。

Worker のライフサイクルとメッセージルーティングは [Sessions](../sessions/) と [Agent Computer Worker](../agent-computer-worker/) を参照してください。
