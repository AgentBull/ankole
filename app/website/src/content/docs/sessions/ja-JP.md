---
title: Sessions
description: Agent の実行、共有履歴の読み取り、単一 writer のフェンスと復旧。
section: Developer guide
order: 103
---

Session は一つの Agent の実行単位です。キーは `{agent_uid, session_id}` です。同じ Agent の複数の Session は並行実行でき、各 Session は `Ankole.Sessions` の一つの Driver が進めます。

Conversation は共有発言を保存します。参加する Agent はそれぞれ別の Session を使い、AIGateway がそのモデル履歴を保存します。汎用 Signal は Conversation のない Session にも送れます。

## 単一 writer

DynamicSupervisor が一時的な `:gen_statem` Driver を開始します。`:global` は各 Session のキーを Erlang クラスタで一つの名前にします。永続 workspace の epoch が書き込みフェンスです。准入が epoch を進め、Driver のトランザクションが行ロックの下で確認します。ネットワーク分断後の古い Driver はコミットできません。

## 永続入力とモデル履歴

Signal は永続 inbox です。AIGateway の Response チェーンはモデル出力とツール結果を記録します。control plane のツールは副作用と receipt を一緒にコミットします。Driver はラウンドの結果をチェーンに書き、同じトランザクションで receipt を削除します。代替 Driver はこれらの事実から進捗を復元します。

モデルリクエストの境界で、Sessions は現在の Conversation の Message を読みます。実際のリクエスト metadata に読み取り位置を保存し、現在の main と steer の Message を背景から除きます。共有履歴は文脈を提供しますが、過去の作者の権限は提供しません。准入は現在の依頼者を確認します。

Signal の完了と最終返信の意図を一緒にコミットします。内部修訂は返信の所有者を保ち、撤回や retry 後もツール結果を読めます。`/compress` は feedback と checkpoint で完了し、通常の最終モデル Response は不要です。

## Worker と操作の識別子

環境ツールや Codex が computer を必要とするとき、Agent の Worker を要求します。環境作業は Agent・Session・Signal に対応する `RunRef` を使います。Codex の `JobTurnRef` は Job と attempt も識別します。操作は固有の識別子を持つため、代替 Driver は進行中の作業を引き継げます。

RuntimeFabric は Worker ごとに一つの Phoenix Channel を使い、Phoenix Tracker がノード間で位置を解決します。Worker の generation と incarnation が古いルートを拒否します。各 Worker は一つの Agent に結び付いています。

## 復旧

Signals は受け入れトランザクションで永続の Oban 起動を保存し、呼び出し元のドメイン書き込みと一緒にコミットします。Reconciler は開始済みの試行を含む期限到来の open 入力を走査し、Driver を起こすか再作成します。Workflow の所有者には失われた RunServer と cleanup の修復を求めます。保存した `last_attempt_at` と失敗予算が再試行を制御します。

ネイティブ・外部チャット、定時作業、業務イベントはこの実行規則を使います。[Signals](../signals/)、[Agent loop](../agent-loop/)、[Agent Computer Worker](../agent-computer-worker/) も参照してください。
