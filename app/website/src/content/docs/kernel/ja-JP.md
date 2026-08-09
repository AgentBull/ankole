---
title: Rust Kernel
description: 共有ネイティブレイヤー。認可、RuntimeFabric transport、AI データプレーンのプリミティブの 1 つの Rust 実装であり、Elixir control plane と Bun worker の両方からロードされます。
section: Developer guide
order: 109
---

Ankole は 2 つのホスト runtime で動きます。Elixir control plane と Bun worker です。いくつかの振る舞いは、両側で同じ意味でなければなりません。Rust Kernel は、その共有ネイティブセマンティクスが置かれる場所です。このページでは、`app/kernel` の実際のコードに対して kernel を対応づけます。

最初に決定的な性質を示します。kernel は、2 つの binding レイヤーを通じて 2 つのホストからロードされる 1 つの Rust crate であり、Elixir アダプター付きの Bun パッケージでも、Bun アダプター付きの Elixir NIF でもありません。Rust が低レベルのセマンティクスを所有し、binding はホストの型、命名、エラーを変換するだけです。両方の runtime が信頼しなければならない振る舞いは、binding を後回しにして、まず Rust としてここに置かれます。

## 2 つのホスト、1 つの実装

crate は相互排他的な feature flag でビルドされます。Bun の N-API 用の `napi` と、Elixir の Rustler 用の `nif_dev`/`nif_prod` です。つまり、同じソースが 2 つのネイティブ addon にコンパイルされます。グローバルな mimalloc アロケータが明示的に設定されます。長時間実行するホストにロードされるネイティブ addon は、N-API と NIF の両ビルドでアロケータの振る舞いを同一に保つ必要があるからです。

binding 面もこれに対応します。Elixir 側では、`Ankole.Kernel` は Rustler モジュールであり、ネイティブ crate がロードされるまで、その関数は `:erlang.nif_error(:nif_not_loaded)` にフォールバックします。`aead_encrypt`、`authz_authorize`、`runtime_fabric_router_start`、`universal_ai_client_open_nif`、`gen_uuid_v7`。Bun 側では、同じ crate が N-API addon として出荷されます。名前は異なりますが、振る舞いは変わりません。

## 共有 kernel が存在する理由

kernel は、Bun 側と Elixir 側が同じネイティブ振る舞いに対して別々の意味を発展させるのを防ぐために存在します。これがなければ、認可評価、fabric フレーミング、AI streaming が 2 つの実装の間で乖離し、一方の側で下した決定が他方の側の決定と食い違う可能性があります。信頼された振る舞いを Rust に一度置き、binding を後回しにすることが、2 つの runtime を互いに誠実に保つ方法です。

## 共有面

4 つのモジュールが共有セマンティクスを担います。

- **`common/`** — ホスト中立のプリミティブ。AEAD token の暗号化と復号、key 導出、ハッシュ化、エンコーディング、UUID ヘルパー（`gen_uuid_v7` を含み、Elixir には `gen_uuid_v7/0`、Bun には `genUUIDv7()` として公開）、JWT ヘルパー、電話番号の正規化。これらは、両方の runtime が手にする小さな信頼された操作です。
- **`authz/`** — snapshot のみの認可評価。`authorize` と `authorize_all` は `AuthzSnapshot` を受け取り、`AuthzDecision` を返します。CEL 条件の検証とリソースパターンのマッチングもここにあります。これが [Principal and AuthZ](../principal-authz/) ページが、control plane による snapshot の組み立てを説明している決定論的評価器です。
- **`runtime_fabric/`** — RuntimeFabric v1 エンベローププロトコル。lane、耐久性クラス、相関ルール、turn/control/progress/RPC ボディのセマンティクス。ホストエンコードされた protobuf バイトに対して検証されます。唯一の構造宣言は `proto/envelope.proto` で、各ホストはそこから独自の codec を導出します。Rust では `prost-build`、Elixir では `protox`、TypeScript では `protoc-gen-es`。どのホストも構造を独自に発明しません。
- **`universal_ai_client/`** — 準備済みの AI provider リクエスト向けの、feature ゲート付きネイティブ非同期 streaming クライアント。アップストリームの HTTP SSE/EventStream と WebSocket トランスポート、provider 応答の正規化、ダウンストリームの SSE/WebSocket チャンクエンコーディング、demand credit、キャンセル。これが [AIGateway](../ai-gateway/) が provider と話すために使う AI データプレーンのプリミティブです。

## ZeroMQ トランスポート

`runtime_fabric/transport/` の中で、kernel は auth、config、router、dealer、framing モジュールに分かれた ZeroMQ ROUTER/DEALER トランスポートを所有します。control plane から worker へのライブ fabric は、ここで実際に動きます。

- **ZAP/PLAIN worker 認証** — worker は、認証 key で認証された後、fabric がそのトラフィックを受け入れます。
- **必須ルート送信** — ルーティングできない送信は、黙って落とすのではなく、明示的に失敗します。
- **有界 socket オプション** — socket は、無制限のキューとそれがもたらす失敗モードを防ぐように構成されています。
- **生の `ANKOLE_FILE/1` worker ファイル multipart フレーム** — control plane と worker の間のファイル転送は、RPC lane とは異なる生の multipart フレームとして、同じトランスポートを利用します。

トランスポートは意図的に Rust 所有です。フレームの落下やルーティング間違いの送信は、worker の返信が誤った session に届くことを意味する唯一の場所であるため、信頼された振る舞いはここにあり、両ホストがそれを呼び出します。

## 境界

kernel と 2 つの runtime の境界は明確で、それぞれ共有セマンティクスのルールの帰結です。

- **Actor Runtime との間。** control plane は actor 状態、activation fence、永続トランスクリプトを所有します。kernel は、決定論的な認可評価と、turn、progress、RPC エンベロープを運ぶトランスポートを所有します。Actor Runtime が worker の返信を fence と照合するとき、principal を認可した決定ロジックは kernel コードであり、fence の行自体は control plane の状態です。
- **Agent Computer Worker との間。** worker はライブ実行を所有します。kernel は、worker の turn が provider に届くために使う AI streaming クライアントと、worker の progress フレームとファイルフレームを戻すトランスポートを所有します。worker は streaming やフレーミングを再実装しません。対称方向で control plane が呼ぶのと同じネイティブ面を呼びます。
- **AIGateway との間。** ゲートウェイは provider ルーティングと credential を所有します。kernel は線上バイト、つまり HTTP と WebSocket トランスポート、応答の正規化、呼び出し元が最終的に受け取るチャンクエンコーディングを所有します。

## kernel ではないもの

ホスト固有の振る舞いのための場所ではありません。片方の runtime だけが必要とするもの（Phoenix plug、Bun tool、console route）は、その runtime に残ります。kernel は、両方が信頼しなければならないものだけを取り込みます。actor 状態や provider credential の第二の権威でもありません。それらは control plane のものです。また、ホストが置き換えられるオプションの配管でもありません。要点は、2 つの runtime が、それらの間の境界を越える振る舞いについて 1 つの意味を共有することであり、その意味は Rust だということです。

## 次のステップ

- kernel が実行する認可評価については [Principal and AuthZ](../principal-authz/) を参照してください。
- kernel がエンベロープを運ぶトランスポートについては、[Actor Runtime](../actor-runtime/) と [Agent Computer Worker](../agent-computer-worker/) のページを参照してください。
- kernel が提供する AI streaming については [AIGateway API](../ai-gateway/) を参照してください。
