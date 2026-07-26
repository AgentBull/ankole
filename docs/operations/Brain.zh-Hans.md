# 部署和维护 Brain

Brain 把当前词条、外部资料状态、Dreaming 进度和审计记录保存在控制面的
PostgreSQL 中。聊天原文仍由 SignalsGateway 保存。Console 的 Brain 状态页是唯一健康
面，`memory_health_check` 复用同一组查询。

## 准备 PostgreSQL

Brain 要求 PostgreSQL 18、`pg_search` 和 `vector` 扩展。PostgreSQL 启动前必须预加载
`pg_search`。迁移前，在 `DATABASE_URL` 实际指向的服务器上检查：

```sql
SHOW server_version_num;
SHOW shared_preload_libraries;

SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('pg_search', 'vector')
ORDER BY name;
```

`server_version_num` 不能小于 `180000`，两个扩展都必须可用，
`shared_preload_libraries` 必须包含 `pg_search`。修改预加载设置后必须重启
PostgreSQL。

迁移会安装两个扩展。迁移后检查：

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_search', 'vector')
ORDER BY extname;
```

不要改成 PostgreSQL 内置全文搜索或外部向量库。Brain 的索引和控制面事务依赖当前
两个扩展。

## 执行 Brain V2 清切迁移

Brain V2 不提供 V1 数据转换和降级路径。迁移会先永久清空全部 Brain V1 所属表，
再安装 V2 schema。迁移前先备份必须保留的信息。不要增加 V1 store 名称的兼容读取。

本地 Devkit PostgreSQL 已包含扩展：

```sh
bun run services:start
bun run kit app-db migrate
```

如果确定本地数据库可以整体丢弃，可以重建：

```sh
bun run kit app-db rebuild --yes
```

这个命令会删除完整应用数据库，执行前先备份。Release 或 Helm 部署也要先检查
PostgreSQL、备份，再让迁移 init container 成功运行，最后启动新版控制面。不要让 V1
和 V2 控制面同时连接一个数据库。

迁移后检查固定共享主体和库名：

```sql
SELECT uid, type
FROM principals
WHERE uid = 'brain-shared';

SELECT owner_uid, store_key, count(*)
FROM brain_entries
GROUP BY owner_uid, store_key
ORDER BY owner_uid, store_key;
```

合法库名只有 `shared`、`self`、`dm:<principal-uid>` 和
`channel:<channel-id>`。没有 `public` 兼容库。

## 配置模型

在 Console 中配置模型提供商和 Agent ModelProfile。模型与提供商选择保存在数据库中；
不要把模型 ID 或 API key 写进 Brain 环境变量。

| 模型档位 | 用途 | 要求 |
| --- | --- | --- |
| `primary` | Agent 正常回合和选择 `memory_*` 工具 | Agent 工作必需 |
| `light` | Stage A 情景摘要、Stage B locator 和 curator | 负责该材料的 Agent 必须具备 |
| `embedding` | 所有词条块、情景摘要和查询向量 | 全局嵌入模型 Agent 必须具备 |
| `rerank` | 可选的全局检索重排 | 仅启用重排时需要 |

Stage B 只整理 Agent 主体，并使用该 Agent 自己的 `light` 档；人员主体与系统
主体不能拥有 Stage B 运行。Stage A 在频道可见且已启用的 Agent 中，确定性选择
UID 字典序最小、能解析 `light` 档的 Agent。系统不再有
`brain.dreaming.model_agent_uid`。

通过全局 `brain.embedding` 配置一个实例级向量空间：

```json
{
  "enabled": true,
  "model_agent_uid": "agent-uid-with-embedding-profile",
  "dimensions": 1024
}
```

`dimensions` 必须与模型真实输出一致，可取 1 到 4096。Agent、档位或维度缺失时，
向量管线会标为 unavailable，状态页出现红色告警。PostgreSQL 用尾部补零的
`vector(4096)` 包络存储；超过 4096 维必须新建迁移。HNSW 候选召回使用前 4000 维，
候选的最终顺序使用完整存储向量。

### 安全更换嵌入模型

先修改全局配置。下一次词条块或情景摘要嵌入批任务会调用
`Ankole.Brain.Embedding.prepare_space/2`，把旧模型或旧维度生成的向量重新置为
`pending`。重复运行两个批任务，直到 pending 为零：

```sh
/app/bin/ankole eval 'IO.inspect(Ankole.Brain.embed_pending_blocks(500))'
/app/bin/ankole eval 'IO.inspect(Ankole.Brain.embed_pending_episodes(500))'
```

不要混用两个模型或两个维度的向量。每行都记录
`embedding_model_agent_uid` 和 `embedding_dimensions`，状态页会报告不属于当前空间的
旧向量。

可选精排在 `brain.search` 中配置，模型 Agent 必须有 `rerank` 档。默认关闭，因此正常
召回不会额外依赖一次模型调用。

## 配置运行策略

Brain 注册五组 AppConfigure：

- `brain.embedding` 选择唯一的全局向量空间。operator 未选模型 Agent 和维度前默认
  关闭。
- `brain.search` 配置 30 天半衰期、`0.5` 词条衰减下限和可选精排。
- `brain.dreaming` 按 Agent 覆盖启用状态和微批限制。Agent 默认启用；human 与
  系统主体没有 Stage B 消费面。
- `brain.sources` 默认启用 connector 轮询，间隔 15 分钟，单块上限 1500 token。
- `brain.knowledge` 配置 1500 token 的 pinned memo 预算和默认 10 条召回结果。

Stage B 在材料静默时间或积压条数达到任一门槛后入队，默认是 30 分钟或 50 行。
`token_limit` 和 `mutation_limit` 为 `0` 表示 operator 没有限制。模型、校验、预算或
事务失败时，游标都不推进。

Stage B 的 task outcome 只接受已有最终 Response 的 `im.message.addressed`、
`signal.action.invoked`、`check_back_later.wakeup` 和 `cron.fire`。其他
ActorEvent 类型不作为策展材料。

所有字段和默认值见 [Brain 设计文档](../design-docs/Brain.md)。

## 查看唯一状态面

在 Console 打开该 Agent 的 Brain 状态页。顶层 `status` 为 `error` 表示至少存在一条
告警。按因果顺序排查：

1. **全局嵌入配置。** 先修复关闭、不完整或无法解析的 `brain.embedding`，再处理
   pending 数量。
2. **旧向量空间。** 重新生成模型 Agent 或维度不符合全局配置的向量。
3. **Stage A 可用性。** 查看每个频道的 processor 和 `light` 档；选择失败原因写在
   `unavailable_reason`。
4. **Stage B 可用性。** 检查正在整理的主体是否配置 `light` 档，以及最近一次成功时间。
5. **失败或卡死策展。** retryable Stage B 任务出现在 `stage_b.retryable_jobs`，
   只有在最后一次尝试时才产生 `curation_jobs_failing` 告警，之前的重试不需要
   运维者介入。Oban Lifeline 会在执行 30 分钟后救援任务；同一主体反复
   出现时，继续查服务商和校验错误。
6. **向量积压或失败。** 修复服务商或档位，再重新跑对应批任务。
7. **内容纪律。** 通过正常带版本的 Brain 操作处理日期命名、近重名、超过 200 投影
   行、零正文、超预算 memo、引用和来源问题。

Console 不可用时，可以在 Release 中读取同一状态：

```sh
/app/bin/ankole eval 'IO.inspect(Ankole.Brain.status("agent-uid"), limit: :infinity)'
```

常用数据库检查：

```sql
SELECT embedding_state, embedding_model_agent_uid, embedding_dimensions, count(*)
FROM brain_entry_blocks
GROUP BY embedding_state, embedding_model_agent_uid, embedding_dimensions
ORDER BY embedding_state, embedding_model_agent_uid, embedding_dimensions;

SELECT embedding_state, embedding_model_agent_uid, embedding_dimensions, count(*)
FROM brain_episodes
GROUP BY embedding_state, embedding_model_agent_uid, embedding_dimensions
ORDER BY embedding_state, embedding_model_agent_uid, embedding_dimensions;

SELECT scope_kind, scope_key, cursor_entry_observed_at,
       unavailable_reason, metadata, updated_at
FROM brain_cursors
ORDER BY scope_kind, scope_key;

SELECT state, worker, args, attempted_at, attempt, max_attempts
FROM oban_jobs
WHERE worker LIKE 'Ankole.Brain.Jobs.%'
ORDER BY inserted_at DESC
LIMIT 100;
```

不要手工推进游标来掩盖模型或写入失败。

## 手动执行维护

为一个主体运行一次 Stage B：

```sh
/app/bin/ankole eval 'IO.inspect(Ankole.Brain.run_dreaming("agent-uid"), limit: :infinity)'
```

写入成功返回 `status: :completed`；没有符合条件的新材料返回
`status: :no_new_material`。

运行待处理向量批次：

```sh
/app/bin/ankole eval 'IO.inspect(Ankole.Brain.embed_pending_blocks(500))'
/app/bin/ankole eval 'IO.inspect(Ankole.Brain.embed_pending_episodes(500))'
```

按来源行 UUID 同步一个已注册 connector 来源：

```sh
/app/bin/ankole eval 'IO.inspect(Ankole.Brain.SourceSync.sync("source-row-uuid"), limit: :infinity)'
```

当前版本只有通用 connector 运行时和确定性 fake connector 测试，没有真实飞书文档
connector。只有安装已经注册了 connector 时才能使用这个命令。Lark adapter 的聊天
收发与文档来源同步是两个独立能力。

## 查看外部资料

手工文件的 `capture_method` 是 `file`。其原始字节不可修改，并通过显式资料学习回合
进入知识。connector 来源使用 connector ID 作为 `capture_method`，保存当前 revision
和当前导出正文。

```sql
SELECT document_id, capture_method, connector_id, revision, sync_state, lock_version,
       title, source_url, byte_size, sha256, last_synced_at
FROM brain_retained_sources
ORDER BY inserted_at DESC;
```

每个 connector 来源在 `shared` 中对应一个只读 `external_document` 镜像词条。revision
不变时只更新检查时间；revision 变化但正文摘要不变时可以只更新 metadata；正文变化
时整页替换；来源删除或失权时撤下镜像。不要通过 SQL 修改镜像正文或移除镜像标记。

并发同步使用 connector I/O 之前读到的来源行版本。陈旧结果返回
`{:error, :source_sync_conflict}`，且不修改来源或镜像。定时任务会重试该错误；手工同步
遇到该错误时重新运行命令。

粘贴文本和抓取的 URL 文本是普通可编辑词条，不是不可变的 connector 快照。

## 审计和恢复

Console 审计页可以按库、操作、作者、Dreaming 运行和日期筛选。批量恢复前先预览。
控制面在一个事务中从新到旧应用逆操作。

如果当前值已经不符合审计记录的预期，恢复会返回冲突，整次操作不改任何内容。人工
纠正也必须使用 Brain 操作，以保留版本检查、引用规则和审计记录。普通检索不读取审计
历史。

外部平台撤回一条聊天来源时，Brain 只撤销仍符合预期值的改动，并删除带精确来源标记
的正文块；后续人工或 Agent 修改优先。

## 周期任务

Oban 高频扫描，再在任务内部应用资格门槛：

- 每 5 分钟检查 Stage A；
- 每 5 分钟处理情景摘要向量；
- 每 5 分钟处理词条块向量；
- 每分钟检查 Stage B；
- 每分钟检查 connector 来源，并按每个来源的配置间隔决定是否同步。

这些是控制面维护任务，不是用户 Schedule。

## 运行专用验收套件

真实模型 Brain 套件不进入默认 gate，也不进入 `tools/e2e/run --all`：

```sh
OPENROUTER_API_KEY=... tools/e2e/run --brain-real-llm
```

可以按 ExUnit tag 单独运行：

```sh
tools/e2e/run --brain-real-llm --only brain_dm_isolation
tools/e2e/run --brain-real-llm --only brain_unified_recall_ranking
tools/e2e/run --brain-real-llm --only brain_episode_paraphrase
tools/e2e/run --brain-real-llm --only brain_dreaming_convergence
tools/e2e/run --brain-real-llm --only brain_source_mirror_sync
tools/e2e/run --brain-real-llm --only brain_retraction
```

Fake Feishu 只替代客户端界面。套件仍经过 Lark 传输、SignalsGateway、ActorRuntime、
Docker Agent Computer、OpenRouter、Brain RPC、PostgreSQL 和 outbox。来源镜像场景使用
契约规定的 fake connector，因为真实飞书文档 connector 属于下一期。

失败时先定位第一个边界：PostgreSQL 前置条件、ModelProfile、消息接收与 Actor 分配、
执行进程镜像、模型工具选择、Brain RPC、数据库事务或 outbox。服务商额度和传输故障
属于外部阻塞，不能因此削弱存储断言。
