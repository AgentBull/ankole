---
title: Sessions
description: Agent の実行単位、共有会話履歴の読み取り、単一 writer フェンス、および障害復旧の仕組みを説明します。
section: Developer guide
order: 103
---

Session は単一の Agent における実行単位であり、`{agent_uid, session_id}` をキーとして識別されます。同一 Agent でも複数の Session を並行して動かせ、各 Session の進行は `Ankole.Sessions` の単一の Driver プロセスが担います。

一方、Conversation は参加者間の共有発言履歴を保存する場所です。同じ Conversation に参加している複数の Agent はそれぞれ独立した自身の Session を持ち、モデルとのやり取りの履歴は AIGateway 側で管理されます。また、特定の Conversation に紐付かない汎用 Signal を Session へ直接送ることも可能です。

## 単一 writer

実行時には DynamicSupervisor が一時的な `:gen_statem` の Driver プロセスを起動し、`:global` によって各 Session キーが Erlang クラスタ全体で一意な名前として登録されます。書き込みの排他制御（書き込みフェンス）を担うのは、永続ワークスペースに記録された `epoch` です。新しい実行を受け入れる際に `epoch` が進められ、Driver の各トランザクションは行ロックを取得した状態でこの値を検証します。そのため、ネットワーク分断などによって取り残された古い Driver が後からコミットを完了させることはできません。

## 永続入力とモデル履歴

Signal は永続化された受信トレイ（inbox）として機能し、AIGateway の Response チェーンがモデルの出力とツール実行結果を順番に記録します。コントロールプレーン側のツールは、ドメインへの副作用と実行レシート（receipt）を同一トランザクションでコミットします。その後、Driver がそのラウンドの結果を Response チェーンへ書き込み、同じトランザクション内でレシートを削除します。プロセス障害などで新しい Driver に引き継がれた場合も、これらの永続レコードから途中の進行状態を正確に復元できます。

モデルリクエストを組み立てる境界では、Sessions が現在の Conversation から Message 一覧を読み取ります。その際、実際のリクエストメタデータに読み取り位置を記録し、今回処理中の main メッセージおよび steer メッセージを背景履歴から除外して重複を防ぎます。なお、共有の会話履歴はあくまで推論のための文脈として渡されるだけであり、過去の発言者の権限まで引き継ぐわけではありません。受け入れ判定（アドミッション）では必ず今回の依頼者の権限を検査します。

また、Signal の完了記録と最終返信の送信意図は同一トランザクションでコミットされます。内部的な応答の書き直しが発生しても返信の所有者は維持され、メッセージの取り消しやリトライが行われた後でも実行済みのツール結果を引き続き参照できます。なお、`/compress` コマンドはフィードバックとチェックポイントの保存をもって完了するため、通常の最終モデル Response の生成は行われません。

## Worker と操作の識別子

環境ツールや Codex の実行で計算環境が必要になると、その Agent 専用の Worker が要求されます。環境ワークスペース上の操作には Agent・Session・Signal に対応する `RunRef` が使われ、Codex の `JobTurnRef` にはさらに Job と attempt の識別情報も含まれます。すべての操作に固有の識別子が付与されているため、Driver が入れ替わった際にも実行中の作業を安全に引き継げます。

通信面では、RuntimeFabric が Worker ごとに 1 本の Phoenix Channel を張り、Phoenix Tracker がクラスタノード間の接続先を解決します。接続時には Worker の `generation` と `incarnation` が検証されるため、古い世代のルートは拒否されます。各 Worker は常に単一の Agent に専属で紐付いています。

## 復旧

Signals はイベント受け入れ時のトランザクション内で永続的な Oban ジョブを登録し、呼び出し元のドメイン書き込みと同時にコミットします。Reconciler はすでに試行が始まっているものも含めて期限到来の未完了（open）入力を走査し、対応する Driver を起こすか再生成します。また、Workflow 側で RunServer が失われていた場合やクリーンアップが未完了だった場合は、Workflow の所有者に修復を要求します。再試行の間隔と上限は、保存された `last_attempt_at` と失敗バジェットによって制御されます。

ネイティブチャット、外部チャット、スケジュール実行、業務イベントはいずれもこの共通の実行基盤の上で動作します。あわせて [Signals](../signals/)、[Agent loop](../agent-loop/)、[Agent Computer Worker](../agent-computer-worker/) も参照してください。
