# Brain 部署与运维手册

Brain 把聊天召回、策展知识、显式保留的原始资料、dreaming 游标和审计记录都放在
控制面使用的同一个 PostgreSQL 数据库里。`memory_open` 返回的 Markdown 是关系数据
的投影，不是第二份需要备份或修复的存储。`brain_retained_sources` 的原始字节不可变；
`brain_block_citations` 可由正文中的严格 `src:` 标识符重建。

## PostgreSQL 前置条件

必须使用 PostgreSQL 18，并安装 `pg_search` 与 `vector` 扩展包。PostgreSQL 启动前，
`shared_preload_libraries` 必须包含 `pg_search`；修改这个设置后需要重启 PostgreSQL，
仅 reload 不生效。

迁移前，对 `DATABASE_URL` 实际指向的服务器运行：

```sql
SHOW server_version_num;
SHOW shared_preload_libraries;

SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('pg_search', 'vector')
ORDER BY name;
```

`server_version_num` 必须不小于 `180000`，两个扩展包都必须 available，preload 列表
必须包含 `pg_search`。应用迁移会对两个扩展执行 `CREATE EXTENSION IF NOT EXISTS`，
并创建 BM25 索引。迁移后再验证：

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_search', 'vector')
ORDER BY extname;
```

扩展缺失时不能暗中改用 PostgreSQL 内置全文搜索或外部向量库；那会改变 Brain 的
事务边界和降级承诺。

## 创建、重建与迁移

本地 devkit 镜像已经包含两个扩展，并以
`shared_preload_libraries=pg_search` 启动 PostgreSQL：

```sh
bun run services:start
```

Ankole 尚未发布，不提供 Memory → Brain 兼容迁移。若本地数据库已经记录过旧版
Memory migration，只修改原 migration 文件不会让 Ecto 重跑同一版本；必须显式重建：

```sh
bun run kit app-db rebuild --yes
```

这个命令会删除数据库。重要数据必须先备份。全新安装或已经是 Brain schema 的数据库
只运行待执行迁移，不删除数据：

```sh
bun run kit app-db migrate
```

Release/Helm 部署时，先检查 PostgreSQL、备份，再让 control-plane migration init
container 执行一次，成功后才启动新版控制面。在这次尚未发布的 schema 替换期间，
不要让新旧控制面同时连接同一数据库。

## ModelProfiles

模型选择属于 PostgreSQL-backed 运行时配置。Provider 行和 agent ModelProfiles 应从
Console 配置；不要把模型 id 或 API key 塞进 Brain 环境变量。

| Profile | 服务的路径 | 要求 |
| --- | --- | --- |
| `primary` | 正常 agent turn 与 `memory_*` 工具调用 | agent 正常工作必需 |
| `light` | dreaming 阶段 A 的情景摘要 | 全局 `brain.dreaming.model_agent_uid` 必需 |
| `heavy` | dreaming 阶段 B 的知识归并 | 每个启用 principal 的 scoped 模型归属方必需 |
| `embedding` | episode、知识正文块与查询向量 | 共享 episode 使用全局模型归属方；知识正文块与查询可回退到 owner agent 的 profile |
| `rerank` | 可选的检索精排 | 只在 `brain.search.rerank_enabled=true` 时配置 |

启用共享 channel episode 时，全局 `brain.dreaming.model_agent_uid` 应指向同时具有
`light` 与 `embedding` profile 的模型归属方；阶段 A 和 episode 查询向量使用该
owner。知识正文块索引和知识查询在配置了全局 owner 时同样使用它；未配置时，如果
知识 owner 本身是具有 `embedding` profile 的 agent，则回退到该 agent。每个启用
阶段 B 的 principal 仅在自己不是模型归属 agent 时，才需要通过 scoped
`brain.dreaming.model_agent_uid` 指向具有 `heavy` profile 的 agent；agent owner 默认
回退到自己的 `heavy` profile。缺 profile 是明确的 unavailable 状态，游标不能假装
成功而推进。启用 rerank 时，`brain.search` 还必须指向具有 `rerank` profile 的模型
归属方。

## 阶段 B 的预算与游标安全

阶段 B 对每个参与的 store 使用 scoped `heavy` profile 做两步调用。locator 先读取
episode 摘要和有界的材料预览索引，选择一个按时间连续的材料前缀及主题查询；Brain
再检索相关的当前知识投影，只把这个前缀的完整原文交给 curator。公共库和各私聊库
始终是彼此隔离的模型调用。

`brain.dreaming.token_limit` 非零时，预算覆盖本次运行所有 locator 与 curator 调用的
最终序列化输入，以及各调用声明的输出预留，并跨全部 store 累计。事务只提交实际交给
curator 的全局连续材料前缀；被 locator 或预算排除的材料仍留在 principal 高水位之后，
等待下次运行。locator 输出非法、模型失败、预算不足或 mutation 失败都不能推进游标。
配置为 `0` 时维持“不设 token 上限”的既定语义。

## 运维检查

当前知识状态在 `brain_entries`、`brain_entry_blocks`、`brain_entry_relations`。
用户明确保存的 URL、PDF、文件和粘贴文本在 `brain_retained_sources`；引用索引在
`brain_block_citations`。
`brain_audit_log` 是 append-only 的恢复证据，正常检索不读取它。`brain_cursors` 记录
阶段 A 的 channel 进度和阶段 B 的 principal 进度；`brain_episodes` 是聊天导航索引。

常用查询：

```sql
SELECT owner_uid, store_key, name, type, lock_version, updated_at
FROM brain_entries
ORDER BY updated_at DESC;

SELECT owner_uid, store_key, author_kind, embedding_state, count(*)
FROM brain_entry_blocks
GROUP BY owner_uid, store_key, author_kind, embedding_state;

SELECT scope_kind, scope_key, cursor_entry_observed_at, unavailable_reason, updated_at
FROM brain_cursors
ORDER BY scope_kind, scope_key;

SELECT actor_kind, action, entry_id, block_id, before, after, inserted_at
FROM brain_audit_log
ORDER BY inserted_at DESC
LIMIT 100;

SELECT s.document_id, s.owner_uid, s.store_key, s.capture_method, s.title, s.byte_size,
       s.sha256, s.inserted_at, count(c.block_id) AS citing_blocks
FROM brain_retained_sources AS s
LEFT JOIN brain_block_citations AS c ON c.document_id = s.document_id
GROUP BY s.id
ORDER BY s.inserted_at DESC;
```

Console 的知识列表会搜索名称、别名、简介和正文块，并使用稳定游标分页；浏览器不会把
筛选变成无边界的整表加载。**查看审计** 页面可按知识库、操作、执行者、dreaming
运行 id 和日期筛选。批量恢复刻意要求先预览：勾选精确审计记录并确认后，服务端才在
一个事务里按从新到旧的顺序执行逆操作。若受影响字段已经被并发修改，整个选择都会以
冲突失败，不会覆盖较新的工作。可用 dreaming 运行 id 定位并按需撤销一次错误运行；
这不代表审计流水变成了可检索的知识版本库。

Operator 可在 release 内通过公开 facade 同步触发一次阶段 B：

```sh
/app/bin/ankole eval 'IO.inspect(Ankole.Brain.run_dreaming("agent-uid"), limit: :infinity)'
```

有新材料并成功提交时状态是 `:completed`；principal 游标已经追平时是
`:no_new_material`。不能为了掩盖模型失败或非法 mutation 而手工推进游标。

Console 的“学习资料”会先提交不可变原文，再启动 `brain.source.learn`。若没有可用
Worker，资料页会显示为已保存并允许重试；不要因为学习没排上而手工删除原文。多个
知识页可以引用同一资料。资料的 URL 快照超过复核窗口只表示需要检查，不能据此直接
宣称来源已漂移。资料学习回合只能创建带首块的页面，或追加、纠正正文块，并且正文
必须精确包含当前资料的 `src:`；控制面会拒绝删除、仅改 metadata、或无引用的写入，
避免把临时解析器故障绕路写成长久知识。

Console 的 Brain 分为“词条、资料、待复核、审计、Dreaming”五个任务面。“保存资料并
学习”在交互上是一个动作，但服务端仍先提交原文、再启动 ActorEvent，因此第二步失败
不会丢资料。资料学习状态直接来自 ActorEvent 和审计流水，没有额外的学习任务表：
未读完或迭代耗尽显示“未完整读取”，正常结束但未写知识显示“无需更新”，只有审计中
确有本次来源写入才显示“已整合”。

“整理指南”是每个 principal 唯一的公开 `brain_curation_guide` 词条，只允许人维护。
正文用于约定领域 schema、分类法、建页阈值和更新规则；source learning 与 Dreaming
只把正文语义送给模型，不附带词条 id、锁版本等存储元数据。它不能覆盖服务端固定的
权限、引用和 mutation 约束，因此无需再引入规则引擎或 schema DSL。

同一群聊的原始消息和 channel episode 都按 channel 保存一次；多个 Agent 通过各自的
可见范围和 Brain scope 读取同一份证据，不重复保存或生成向量。每个 Agent 的当前对话
上下文、知识 owner 和私聊库仍彼此独立。对话消息本身就是 SignalsGateway source；若人
粘贴一段对话要求学习，它只是普通的 `paste` retained source，不存在特殊 conversation
source 类型。

“待复核”和 `memory_health_check` 会按需重算确定性候选：失效引用、自动写入但无引用、
可能陈旧的页面、未使用资料、到期复查的 URL、未连接或过长页面、索引失败和超预算
固定记忆。名称只陈述可观测事实；例如 URL 过期不等于已经检测到来源漂移。它们适合在
固定里程碑定期查看，但不是周期性自动修复任务。人的
口头裁决应走与 agent 相同的结构化 Brain operation，保留 lock version 和审计快照。
Console 的“纠正”和“不再成立”同样走该路径，可选原因写进审计 metadata；恢复仍使用
既有审计流水。

## 专用真实模型验收

Brain suite 明确不进入默认 test gate，也不进入 `tools/e2e/run --all`：

```sh
OPENROUTER_API_KEY=... tools/e2e/run --brain-real-llm
```

可按 ExUnit tag 聚焦重跑：

```sh
tools/e2e/run --brain-real-llm --only brain_dm_isolation
tools/e2e/run --brain-real-llm --only brain_dreaming_idempotence
tools/e2e/run --brain-real-llm --only brain_retraction
```

Fake Feishu 只替代难自动化的客户端。Suite 仍真实经过 Lark transport、
SignalsGateway ingress、ActorRuntime、Docker worker、OpenRouter、Brain RPC、
PostgreSQL transaction、outbox dispatch 和平台镜像。判定依据是模型 tool journal、
结构化数据库状态、可恢复审计数据和 succeeded outbox，不做固定提示词文案快照。

失败时先定位第一个断点，再决定改哪里：

1. PostgreSQL 包、preload 或 migration；
2. Provider 或 model profile unavailable；
3. ingress、actor placement 或 stale worker image；
4. 模型工具选择或 Brain RPC 拒绝；
5. 数据库 invariant、cursor 或 audit 不一致；
6. outbox/provider 投递失败。

Provider transport、额度或上游可用性属于外部阻塞，不能据此削弱数据库断言。
