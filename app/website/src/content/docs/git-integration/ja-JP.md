---
title: Git 統合
description: Ankole Agent が通常の会話または Background Agent Job で git をどのように使うか。
section: Guides
order: 303
---

Ankole Agent は、Worker が提供する shell ツールを通じて標準の git コマンドを使用します。同じツールは通常の会話でも Background Agent Job でも利用できます。

最初に決定的な性質を示します。agent は **worker の sandbox 内**で `/agents/<key>/` ファイルシステムに対して git を実行します。特別な git 統合レイヤーはありません。他のすべてと同様に同じ shell ツールを使い、ファイルシステムが workspace になります。`design-md` skill と persona が規約を担い、ツールが実行を担います。

## agent が git でできること

`command` ツールを通じて、agent は sandbox が許可する任意の git コマンドを実行します。

```bash
git clone https://github.com/your-org/your-repo.git
git checkout -b feature/agent-fix
git add -A && git commit -m "Fix: resolve the null-pointer case"
git push origin feature/agent-fix
```

agent は workspace（`/agents/<key>/jobs/<job-id>/` または `sessions/<id>/`）にクローンし、ファイル編集と patch のツールで変更を加え、コミットしてプッシュします。すべて shell 経由で、すべて bubblewrap の制約下で実行されます。

通常の会話では、Agent はフォアグラウンドの shell とファイルツールを使います。作業を Background Agent Job に委任する場合、その Job は独自の workspace で実行され、結果を返すか、静かに終了します。このワークフローについては [Background Agent Jobs](../background-jobs/) を参照してください。

## 必要なもの

- **Git の credential。** **Console → Environment variables** で、SSH key または PAT を `GIT_SSH_KEY` や `GIT_TOKEN` などの暗号化変数として保存します。新しい値は Agent の次の Turn から利用できます。[Environment variables](../worker-env/) を参照してください。
- **worker からアクセスできる repo。** worker は git ホストに到達できるネットワークが必要です。プライベートネットワークでは、worker が git サーバーに到達できることを確認します。
- **必要な場合の Background Agent Job の model profile。** デフォルトのフォールバックで開始するには十分です。Job で異なる provider や model が必要な場合にのみ、この profile を構成します。

## workspace

git repo はセッションまたは Job ごとの workspace にクローンされます。

```text
/agents/<agent-key>/
└── jobs/<job-id>/
    └── your-repo/       # cloned here
        ├── .git/
        └── ...           # the working tree
```

workspace は Agent Home ボリューム上で永続化されます。worker を再起動してもクローンは失われません。レイアウトについては [File management](../file-management/) を参照してください。

## 実践例

PR をレビューするコーディング agent をセットアップします。

1. **Console → Environment variables** で、PAT を `GIT_TOKEN` という名前の暗号化変数として保存します。
2. Agent を作成し、必要な `primary`、`light`、`heavy` profile をバインドします。フォールバックを上書きする必要がある場合にのみ、Background Agent Jobs を別途構成します。
3. repo 名、レビュー基準、ブランチ命名規約を記した `MISSION.md` を作成します。
4. channel で agent にこう依頼します: 「`your-repo` の最新 PR をレビューしてください。クローンしてチェックアウトし、テストを実行し、見つけたことを報告してください。」
5. Agent は `command` を通じてクローン、チェックアウト、テスト実行を行い、結果を報告します。これは会話内で行うことも、Background Agent Job に委任することもできます。

## このガイドではないもの

これは git のチュートリアルではありません。agent は標準の git コマンドを使います。CI/CD 統合でもありません。Ankole は CI を実行せず、repo の CI がコマンド駆動であれば、agent は shell コマンドで CI を起動できます。そしてコードレビュー自動化のガイドでもありません。agent は persona が指示する方法で、shell ツールを通じてコードをレビューします。

## 次のステップ

- shell ツールについては [Code execution](../code-execution/) を参照してください。
- バックグラウンド実行については [Background Agent Jobs](../background-jobs/) を参照してください。
- Git の credential については [Environment variables](../worker-env/) を参照してください。
- ファイルシステムのレイアウトについては [File management](../file-management/) を参照してください。
