---
title: ファイル管理
description: Console で統合ドライブのルートを管理し、Worker の /drive FUSE マウント、添付ファイルの凍結保護、ゴミ箱の保持期間を扱います。
section: User guide
order: 31
---

**日常業務では、チャットで直接ファイルを送るか Pod ページ上で共同作業を行えば十分であり、Agent も `/drive` マウントを直接読み書きします。Console のドライブブラウザーを開くのは、Worker 停止中にテナント内の各ルートを確認したいとき、参照データセットを一括アップロードしたいとき、保存済み成果物を回収したいとき、あるいはフォルダ構成を整理したいときだけです。**

Ankole は共同編集ページとランタイムファイルを**統合ドライブ（Unified Drive）**で一元管理します。`Ankole.Pod` が `pages` ツリー、アクセス権限、ゴミ箱のライフサイクルを所有し、`Ankole.Files` がテナント単位で分離された不変バイトオブジェクトを `file_objects` に格納します（ドキュメント内の埋め込み画像、Base のセル添付、Applet のビルド資産は `pod_files` で管理されるため、ドライブの一覧を散らかしません）。なお、Session や Background Agent Job の作業ディレクトリ（`/workspace`）はドライブではなく永続 Agent Home に置かれます。ストレージバックエンドの構成は [ドライブストレージ設定](../drive-storage/) を、1.x からの移行は [1.0 から 2.0 への更新](../upgrade-to-2/) を参照してください。

## Worker の `/drive` マウントと CLI フォールバック

FUSE 対応の Worker では、ルートスーパーバイザーが各コマンドや Codex プロセスのプライベートマウント名前空間内に `/drive` をマウントしたうえで特権を持たない `uid 1000` へ降格し、現在の実行コンテキストで許可されたルートだけを公開します。

| パス | モード | 内容 |
|---|---|---|
| `/drive/Public` | 読み書き | 共有の Pod Space ページ、フォルダ、ファイル（通常のディレクトリに加え、必要に応じて `._adoc.md`、`._abase`、`._aapp` として投影） |
| `/drive/MyDrive` | 読み書き | Agent がメンバーの Personal Assistant として動作している場合の、その人間のオーナー専用 Private スペース |
| `/drive/AgentDrive` | 読み書き | Agent 専用のプライベートランタイムルート（保存済み出力や会話外で生成された画像など） |
| `/drive/ChatDrive` | 読み書き | 現在の会話ごとに分離されたルート（受信した添付ファイル、会話内で生成した画像、共有成果物） |
| `/drive/Brain` | 読み取り専用 | 現在のルームと依頼者の開示範囲でフィルタされた Brain ナレッジツリー（`._awiki.md`） |
| `/drive/Skills` | 読み取り専用 | **Meta Ankole → Skills** で管理される有効な Skill パッケージ（[Skills](../skills/) を参照） |
| `/drive/AGENTS.md`、`/drive/DESIGN.md` | 読み取り専用 | **Meta Ankole → Agents** で管理される合成済みの行動・デザイン規約（[Agents](../agents/) を参照） |
| `/drive-recovery` | 読み書き（ローカル） | バックグラウンドの VFS 書き戻しが `412` または `422` の競合エラーとなった際に、下書きデータと診断情報を退避するスコープ別ディレクトリ |

起動時のプローブで FUSE をマウントできない環境の Worker では、Ankole は署名付き WorkerFiles リレー経由で動作する `ankole-files` CLI（`list`、`get --node-id`、`put`、`mv`、`rm`）を案内します。また、チャットへのファイル添付に使う `reply_attachment` はドライブの `node_id` と `/drive/...` パスの両方を受け付け、未送信の FUSE 書き込みをフラッシュしてから確定オブジェクトを参照します。

## Console での閲覧とアップロード

1. Console で対象テナントを選択し、**Drive** を開きます。
2. Worker が稼働していなくても、**Pod Space**、**Brain**、メンバーや Agent の **Private** ルート、および各 **Conversation** ルートをそのまま閲覧できます。
3. 保存先フォルダを開いて**アップロード**を選択し、ファイルやディレクトリツリーを追加します。同名の既存ファイルにアップロードすると、そのノードの現在の `object_id` が新しいオブジェクトに更新されます。

参照資料は `customer-research/2026-q3-interviews.pdf` のように用途が分かる安定したパスで整理してください。ドライブへアップロードしただけでは Agent の Turn は開始されないため、処理させたい場合はチャットでパスやページを指定して依頼するか、長期知識として抽出したい場合は **Learn source** から登録してください。

## 添付ファイル、ゴミ箱、保持期間

ルート以外の任意のファイルやフォルダの操作メニューから、移動・名前変更・削除を実行できます（各ルート自体は移動、名前変更、ゴミ箱への移動ができません）。

- **統合ドライブのゴミ箱：** ファイルやフォルダを削除すると、配下のサブツリーごと即座にゴミ箱へ移動し、ドライブや Pod の一覧から非表示になります。ゴミ箱内の項目は `drive.trash_retention_days`（既定値 `30` 日、`0` を指定すると設定変更まで無期限保持）が経過して自動パージされるまで、`manage` 権限を持つユーザーが復元できます。完全削除に備え、重要なデータは定期的な [バックアップ](../backup-and-restore/) の対象に含めてください。
- **凍結保護されるチャット添付ファイル：** メッセージ送信時、Ankole は `message_attachments` にその時点の不変 `object_id` を記録します（ランタイムからは `ankole-pod chat attachment get` で取得可能）。後から元のドライブファイルを上書き・名前変更・移動したりゴミ箱へ入れたりしても、送信済みメッセージの添付ファイルはそのままダウンロードできます。

## Worker 再起動後に引き継がれるもの

統合ドライブのデータは PostgreSQL とオブジェクトストレージに、`/workspace` 内のリポジトリや作業ファイルは永続 Agent Home に保存されるため、どちらも Worker の再起動やイメージ更新をまたいで維持されます。`/workspace` 内にのみ書き出されたファイルは Agent Home 側に残るため、ドライブや Pod から参照・ダウンロードしたい場合は `/drive` へコピー（または `ankole-files put` で保存）させてください。プロバイダーごとのストレージ仕様は [Worker 管理](../worker-management/) を参照してください。

## よくある問題

- **アップロードしたファイルを Agent が見つけられない：** チャットで正確な `/drive/...` パス（またはページリンク）を伝え、実行する Agent にそのフォルダへの `view` 権限があるか確認してください。FUSE 非対応の Worker では、`ankole-files list` と `ankole-files get --node-id` で取得します。
- **生成された成果物がドライブに見当たらない：** Background Agent Job がまだ実行中でないか確認するか、`/workspace` から `/drive/ChatDrive`・`/drive/AgentDrive`・`/drive/Public` のいずれかへコピーするよう Agent に依頼してください。
- **FUSE 書き戻し時の競合エラー：** Worker のキャッシュ書き戻しが確定する前に別の更新や移動が行われた場合（`412` / `422`）、その実行スコープの `/drive-recovery` に下書きバイトが保全されます。
- **サイズ上限エラーでアップロードに失敗する：** ストリーミング対応バックエンド（`fs`、`s3`、`gcs`、`azblob`、`oss`、`cos`、`tos`、`sftp`）ではバックエンド上限と `drive.vfs_max_upload_bytes`（0 以外を設定した場合）の小さい方が適用されます。`postgresql` と `webdav` は 100 MiB、`d1` は 2,000,000 バイト、構造化 Markdown ページの投影は 100 MiB が上限です。
