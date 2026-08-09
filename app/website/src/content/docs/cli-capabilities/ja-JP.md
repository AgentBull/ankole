---
title: Worker CLI の機能
description: Agent の機能を、--help が契約を担う shell コマンドとして出荷し、Agent が関連する判断をする場所に一文のポインタを配置します。
section: Developer guide
order: 114
---

Ankole の機能の一部は、Agent Computer の shell コマンドであり、model に見える tool ではありません。Agent は `gh` や `kubectl` のように shell を通じてコマンドを呼び出します。Webhook エンドポイントコマンドと automation job コマンドはこの形態を取ります。

このページでは、いつ機能をこの形態で出荷するかと、tool 登録、Skill index エントリ、system prompt セクションなしで発見可能かつ正しいものにする開示アーキテクチャを説明します。

## CLI が正しい形態である場合

次のすべてが成り立つとき、機能は CLI 形態に適合します。

- Agent がより大きな shell ワークフロー内で、他のコマンドと並んで使用し、script や background agent job も呼び出す必要がある場合。
- それが 1 つの決定パスでのみ重要である場合。webhook を決して作成しない Agent は、`create-webhook-cli` が存在することを知る必要がありません。
- model が埋める JSON schema を必要とせず、いくつかの flag で入力が運ばれる場合。

model に見える tool は、すべての Turn で context を消費します。CLI は、Agent が関連するパスをたどるまで何も消費しません。

## 開示アーキテクチャ

3 つのルールが tool 登録と Skill インデックスを置き換えます。

**`--help` が契約ドキュメントです。** CLI の `--help` 出力は、機能を正しく使うために Agent が必要とする知識を運びます。それが何か、trust model、保証、完全な使用例がどう見えるか。バイナリと一緒に出荷されるため、説明する振る舞いと同じバージョンになり、独立したドキュメントのように乖離することはありません。他の文脈を持たない読者向けに書き、手順ではなく目標と制約を述べてください。`create-webhook-cli --help` が参考例です。

**ポインタは決定面に置かれます。** 発見性は、Agent がすでに隣接する決定をしている場所に置かれる一文のポインタから生まれます。tool の説明、特定の外部 system を統合する Skill、または別の CLI の `--help`。各ポインタは、機能が関連する条件と、どこで詳細を読むかを述べ、選択を誘導しません。この形態のすべての機能は、Agent が関連パス上で常に訪れる面に、ポインタを少なくとも 1 つ持つ必要があります。機能を意味あるものにするパスこそが、それを開示する面を定めます。

**汎用知識は `--help` にあり、domain 知識は plugin Skill にあります。** 機能のすべての使用に当てはまる契約は `--help` に属します。1 つの外部 system を統合する Skill は、その system が加えるものだけを保持します。たとえば GitHub webhook Skill は、汎用 webhook 契約のために Agent を `create-webhook-cli --help` に誘導することから始まり、hook 登録、ping 検証、配信の調整、GitHub hook クォータだけを扱います。2 番目の統合は、汎用レイヤー全体を無料で再利用します。

## Automation jobs

automation job は、配信のたびに Agent 会話を起こす代わりに、trigger を消費する決定論的な script です。checkback、cron schedule、または webhook endpoint は、`automation_job_id` を指名できます。このフィールドがない trigger は、直接起動の振る舞いを維持します。

Agent は、Agent Home 内にディレクトリを 1 つ作成し、`main.ts` を追加し、セットアップと non-SDK ブランチを手動で確認し、`create-automation-job-cli` でディレクトリを登録します。Worker は、登録時と実行のたびに、実パスでディレクトリとエントリポイントを解決します。現在のファイルを Bun で実行するため、再度登録しなくても編集が反映されます。

各 attempt は最新の Agent WorkerEnv と、現在有効な Skill から呼び出しスコープで生成された `MCPORTER_CONFIG` を受け取ります。Worker は script がどの server を使うかを予測しません。script は mcporter と stdin JSON で、選択した 1 つの MCP tool を呼び出せます。Automation は Skill 指示を読み取らず、永続的な Agent Home mcporter 設定も使いません。

実行 SDK は `context()` と `emitEvent(payload)` を提供します。`context().event` は、直接 trigger が ActorEvent として追加するのと同じ CloudEvents エンベロープです。script は出力なしで成功裏に終了するか、`emitEvent` を 1 回以上呼び出して、永続的な `automation_job.emitted` イベントを所有 session に追加できます。

`context()` と `emitEvent` は、プラットフォームの run 内にのみ存在します。直接の `bun main.ts` 実行では、セットアップとこれらの関数を呼ばないブランチを確認できます。登録後は、各 SDK ブランチにテスト trigger を使い、その永続 run を検査してください。`emitEvent` は stdout にフォールバックしません。その promise は ActorEvent が永続化された後にのみ resolve します。

trigger の消費のたびに、checkback の要求を確定し、cron schedule を進め、または webhook を受け入れる同じ PostgreSQL トランザクション内で永続 run が作成されます。script 例外、非ゼロ終了、タイムアウトは終端の script 結果であり、再試行されません。Worker の喪失はインフラ障害であり、run は既存の Oban wake edge を通じて新しい fenced attempt を受け取ります。リプレイは script の副作用を繰り返す可能性があるため、script は繰り返しが無害になるようにする必要があります。

アクティブな Agent Turn 内でこれらのコマンドを使用します。

- `create-automation-job-cli --dir <path> --label <text> [--wake-on-failure]`
- `list-automation-jobs-cli [--limit <1-500>]`
- `show-automation-job-cli --id <automation-job-id> [--runs <1-100>]`
- `cancel-automation-job-cli --id <automation-job-id>`

Console の Automation Jobs ページには、各 job とその最近の run 状態、attempt、エラー、exit code、有界の stdout/stderr 末尾が表示されます。`create-automation-job-cli --help` は、model 向けの規範ガイドであり続けます。

## 新しい CLI 機能の要件

- 実装を `app/agent_computer/src/cli/` の下に置き、コマンドファミリごとに 1 ディレクトリにします。
- `--help` と `-h` で完全な契約を、stdout、exit 0 で、Turn やネットワーク依存なしに提供します。コマンドラッパーがサブコマンドを前置するため、引数リストのどこでも help flag を検出してください。
- 引数エラーには短い usage 文字列を保持します。契約ドキュメントではありません。
- Agent が機能を必要とする各決定面にポインタの文を追加し、ポインタを好みから自由に保ちます。条件を述べ、`--help` を指名します。
- plugin Skill が機能を外部 system と統合する場合、`--help` へのポインタで Skill を始め、Skill を domain の差分に保ちます。
