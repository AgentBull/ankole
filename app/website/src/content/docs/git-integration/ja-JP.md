---
title: Git 統合
description: 通常の会話や Background Agent Job において、Ankole Agent がどのように git を操作するかを説明します。
section: Guides
order: 303
---

Ankole Agent は、自身の Worker 上にある標準のシェルツールを使って git コマンドを実行します。通常の会話でも Background Agent Job でも、同じツールをそのまま利用できます。

永続 `/workspace` 内の git リポジトリは通常のシェルツールやファイル操作ツールで扱え、Worker インスタンスの入れ替えやイメージの更新を行ってもそのまま保持されます。

## agent が git でできること

Agent は `command` ツールを使い、Worker の実行ユーザーとして git コマンドを実行します。

```bash
git clone https://github.com/your-org/your-repo.git
git checkout -b feature/agent-fix
git add -A && git commit -m "Fix: resolve the null-pointer case"
git push origin feature/agent-fix
```

ワークスペース（`/workspace/jobs/<job-id>/` または `sessions/<id>/`）にリポジトリをクローンし、ファイル編集ツールやパッチ適用ツールで変更を加えたうえで、コミットとプッシュを行います。これらの操作はすべてシェル経由で、Worker のユーザー権限のもとで実行されます。

通常の会話では、フォアグラウンドでシェルツールとファイルツールを使用します。一方、作業を Background Agent Job に委任した場合は、Job ごとに独立したワークスペースで処理が進み、完了後に結果を返すか、通知を出さずに終了します。このワークフローの詳細は [Background Agent Jobs](../background-jobs/) を参照してください。

## 必要なもの

- **Git の認証情報。** GitHub（Cloud または Enterprise）では、**Pod → Connections**（`Ankole.Connectors`）で GitHub App インストールまたは個人 OAuth アカウントを接続する方法を推奨します。Ankole が Turn スコープの `GIT_ASKPASS` クレデンシャルヘルパー（`POST /api/internal/connectors/git-credentials`）を自動注入するため、`WorkerEnv` に静的トークンを保存しなくても HTTPS 経由で `git clone`・`git fetch`・`git push` を認証できます。それ以外の Git ホストを使う場合は、**Console → Environment variables** で SSH キーや PAT を `GIT_SSH_KEY` や `GIT_TOKEN` などの暗号化変数として保存してください（詳しくは [Environment variables](../worker-env/) を参照）。
- **Worker からアクセス可能なリポジトリ。** Worker から git ホストへネットワーク経由で到達できる必要があります。プライベートネットワーク環境では、Worker から対象の git サーバーへ接続できるか事前に確認してください。Docker Compose 環境では、Worker コンテナは `ankole_workers` ネットワークに接続されており、コントロールプレーンとインターネットの双方に通信できるため、パブリックな git ホストへそのままアクセスできます。Helm チャートで `networkPolicy.enabled` を有効にした場合も、Worker Pod からコントロールプレーン、DNS、パブリックアドレスへは通信できますが、プライベートアドレス上の git サーバーについては、該当するアドレス帯が `networkPolicy.workerDeniedCIDRs` に含まれている限りアクセスできません。
- **モデルプロファイル（個別指定が必要な場合のみ）。** Agent は上書きしない限りサイトと Pod のモデルプロファイルを継承し、Background Agent Job も `coding` から `heavy`、`primary` の順でフォールバックします。Background Agent Job で専用の Provider やモデルを使いたい場合にのみ、`coding` プロファイルを設定してください。

## workspace

git リポジトリは、セッションまたは Job ごとのワークスペースにクローンされます。

```text
/workspace/
└── jobs/<job-id>/
    └── your-repo/       # cloned here
        ├── .git/
        └── ...           # the working tree
```

`/workspace` 内のリポジトリは、Worker の入れ替えやイメージの更新を行っても維持されます。ただし、ストレージ障害に備えるため、変更内容はリモートリポジトリへプッシュするか、別途バックアップを取ってください。ビルド成果物や納品物を `/workspace` の外へ共有する場合は、`/drive`（たとえば `/drive/ChatDrive` や `/drive/Public`、FUSE 非対応の Worker ではフォールバックの `ankole-files put`）へ直接書き出します（詳しくは [ファイル管理](../file-management/) を参照）。

## 実践例

PR をレビューするコーディング Agent をセットアップする手順は次のとおりです。

1. **Pod → Connections** で GitHub App または個人 OAuth アカウントを接続します（GitHub 以外のホストでは **Console → Environment variables** に暗号化した SSH キーまたは PAT を保存します）。
2. Agent を作成します。サイトおよび Pod の既定モデルプロファイルが自動で継承されるため、通常の会話や Background Agent Job で別のモデルを使いたい場合にのみ個別の上書きや `coding` プロファイルを設定します。
3. **Meta Ankole → Agents** でその Agent の `AGENTS.md` 規約を編集し、リポジトリ名、レビュー基準、ブランチ命名規約を記載します。
4. チャネルで Agent に次のように依頼します。「`your-repo` の最新 PR をレビューしてください。クローンしてチェックアウトし、テストを実行したうえで、見つかった問題点を報告してください。」
5. 依頼を受けると、Agent は `command` ツールを使ってクローン、チェックアウト、テスト実行を進め、結果を報告します。この一連の作業は会話の中で直接進めることも、Background Agent Job に委任することも可能です。

## このガイドではないもの

このページは git 自体のチュートリアルではなく、Agent が標準の git コマンドをどう実行するかに焦点を当てています。また、CI/CD 連携の機能でもありません。Ankole 自体が CI を実行することはありませんが、リポジトリ側の CI をコマンドから起動できる構成であれば、Agent がシェルコマンド経由で起動することは可能です。さらに、専用のコードレビュー自動化機能を提供するものでもありません。Agent は Persona で指示された方針に従い、シェルツールを使ってコードを読み解きレビューを行います。

## 次のステップ

- シェルツールについては [Code execution](../code-execution/) を参照してください。
- バックグラウンド実行については [Background Agent Jobs](../background-jobs/) を参照してください。
- Git の認証情報については [Environment variables](../worker-env/) を参照してください。
- Agent のドライブについては [File management](../file-management/) を参照してください。
