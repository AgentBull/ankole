---
title: Tool ランタイム
description: worker が Turn で model に提供する tool を収集し、schema 化し、dispatch する仕組み — AgentTool 契約、Turn ごとの組み立て、schema 変換、dispatch 経路。
section: Developer guide
order: 120
---

Turn の間、worker は model が呼び出せる tool 一式を組み立て、各 tool の schema を model が見る JSON Schema に変換し、model が発した各 function call を tool の `execute` 関数へ dispatch し直します。このページではそのランタイムを説明します。`AgentTool` 契約、Turn ごとの tool set の組み立て方、schema の収集方法、loop による call の dispatch 方法です。[Agent loop](../agent-loop/) と [Agent Computer Worker](../agent-computer-worker/) を前提とします。

最初に決定的な性質を述べます。tool は**Turn ごとに組み立てられます**。各 Turn は、computer、web、brain、schedule、background job、その他の現在の source から最終的な tool set を構築します。Agent が所有するグローバルな tool set は存在しません。MCP-backed Skill は computer command tool と mcporter を使います。

## AgentTool 契約

すべての tool は `AgentTool` interface を実装します。ランタイムが関与するフィールドは次のとおりです。

| フィールド | 型 | 役割 |
|---|---|---|
| `name` | string | model が見て呼び出す tool 名 |
| `description` | string | tool が何をするか — model はこれを読んで呼び出すか決めます |
| `schema` | Zod schema | 入力パラメータ。`execute` が実行される前に検証されます |
| `jsonSchema` | JSON Schema（任意） | 生成された Zod schema の代わりに使う、外部の live schema |
| `namespace` / `namespaceDescription` | string（任意） | 関連する外部 tool を 1 つの provider namespace にまとめます |
| `deferLoading` | boolean（任意） | child schema を、選択されるまで Tool Search の背後に置きます |
| `executionMode` | `'parallel' \| 'sequential'` | 同じ response 内の他の tool と並行して実行できるか |
| `isReadOnly` / `isDestructive` | boolean | activity レポートと安全チェックのための metadata |
| `describeActivity` | function | 検証済みパラメータから短い人間可読ラベルを構築します（progress 用） |
| `describeCompletedActivity` | function（任意） | tool 完了時にラベルを結果サマリーで置き換えます |
| `execute` | function | tool を実行します。content、詳細、任意の presentation events を返し、Turn を終了できます |

`execute` 関数が tool の実際の仕事です。検証済みパラメータ（schema がすでに parse と検査を済ませています）、abort signal を受け取り、`AgentToolResult` を返します。これは、model が見る content、ログ用の構造化詳細、任意の reply presentation events、そして任意の actor event 完了フラグまたは Turn 終了フラグです。

## Turn ごとの tool set の組み立て

`text_turn.ts` は各 Turn の開始時に tool set を構築し、カテゴリごとの creator から tool を組み合わせます：

```typescript
tools = [
  createTodoTool(...),
  ...createComputerTools({...}),
  ...webTools,
  ...brainTools,
  ...scheduleTools,
  ...backgroundAgentJobTools,
  ...
]
```

各カテゴリ creator は、Turn の context（worker 環境、agent の home、RPC client、abort signal）で設定された 1 つ以上の `AgentTool` オブジェクトを返す関数です。組み立ては明示的で順序があります — reflection も自動発見も decorator スキャンもありません。tool が配列にあれば利用可能で、なければ利用できません。

Turn ごとの組み立てこそが tool set を動的にします：

- **Skill 知識**は、Agent で現在有効な Skill から投影されます。MCP-backed Skill はドメイン tool を選択し、既存の computer command tool を使って mcporter を呼び出します。
- **Web tool** は、worker の `web_search`/`web_fetch` provider の可用性から作成されます — profile が未バインドなら tool は存在しません。
- **Background job tool** は Turn の context から作成されます — Turn が job の生成をサポートする場合にのみ利用可能です。

最終的な tool set はあくまで Turn ごとの結果であり、Agent の capability database でも既製の connection pool でもありません。

## Schema の収集

model に必要なのは Zod ではなく JSON Schema です。`tool-schema.ts` が各 tool の Zod schema を変換します：

```typescript
export function zodToJSONSchema(schema: z.ZodType): JSONObject {
  const jsonSchema = z.toJSONSchema(schema) as JSONObject
  if (jsonSchema.type !== 'object') {
    throw new Error('function tool parameters must use a root object schema')
  }
  return jsonSchema
}
```

収集された schema — tool ごとに 1 つ、tool 名と description を添えて — は Responses リクエストで model に送られます。具体的な外部 adapter が `jsonSchema` を提供する場合、Ankole は Zod から生成する代わりに、その schema を自分の境界でそのまま送ります。`minimum` や `maximum` などの制約はそこでそのまま保たれます。後の projection は別の native runtime が所有します。Deferred child は選択されるまで Tool Search の背後に残ります。

model が function call を返すと、その引数は JSON 文字列として届きます。`validateToolArguments` は文字列を tool の Zod schema に対して parse し、不正な引数（切り詰められた JSON、code-fenced JSON、不均衡なオブジェクト）には有界な修復の階段を用意します。tool の `execute` が raw の model 出力を受け取ることは決してありません — 受け取るのは schema 検証済みのパラメータです。

## loop が call を dispatch する方法

model の response に function-call 項目が含まれるとき、agent loop は次のように処理します：

1. **Tool map を構築する** — `agentToolMap(tools)` が配列を tool 名をキーとする `Map<string, AgentTool>` に変換します。
2. **引数を検証する** — 各 call の引数文字列を tool の schema に対して parse して検証し、必要なら修復します。
3. **実行する** — 検証済みパラメータと abort signal を渡して tool の `execute` 関数を実行します。`executionMode: 'parallel'` の tool は並行して実行でき、sequential tool は順番に実行されます。
4. **結果を記録する** — `AgentToolResult` を function-call-output メッセージとして AIGateway に送信し、model は次の iteration でそれを参照します。

loop が iteration を所有します。model を呼び、tool を実行し、結果を記録し、model が function call を返さなくなるまで繰り返します。tool が実行タイミングを決めるのではありません。model がリクエストした内容に基づいて loop が決めます。

## このガイドの対象外

これは tool 作成のチュートリアルではありません。新しい tool はカテゴリ creator が返す `AgentTool` オブジェクトであり、既存のカテゴリ（`tools/computer/`、`tools/web/`、`tools/brain/`）がリファレンスです。model の振る舞いのガイドでもありません — model がどの tool を呼ぶかは persona の関心事であり、ランタイムの関心事ではありません。そして agent-loop ページの代わりでもありません。dispatch 経路は loop の一部であり、loop ページがその context です。

## 次のステップ

- tool call を dispatch する loop については、[Agent loop](../agent-loop/) を読んでください。
- tool を実行する Agent Computer Worker については、[Agent Computer Worker](../agent-computer-worker/) を読んでください。
- Skill の背後にある MCP 実行依存関係については、[MCP server リファレンス](../mcp/) を読んでください。
- MCP 依存関係を持つ Skill については、[Skill の作成](../writing-a-skill/) を読んでください。