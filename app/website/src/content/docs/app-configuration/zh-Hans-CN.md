---
title: 系统配置
description: 在 Console 中管理 Ankole 的 AppConfigure 运行时设置，并查阅内置配置键。
section: User guide
order: 43
---

**Console → 系统配置**集中管理可以在实例运行期间调整的设置，例如对话历史压缩、Agent 运行限制、目录同步周期和插件开关。

模型提供商、身份源提供商、聊天渠道和环境变量都有各自的管理页面，不需要在这里重复配置。

## 系统配置与环境变量的区别

AppConfigure 设置保存在 PostgreSQL 中，用于控制 Ankole 运行期间的产品行为。大多数修改会在后续任务中生效，不需要重新部署。

[部署环境变量](../environment-variables/)用于启动控制面、PostgreSQL 和 Worker。修改后需要重启相应进程。

Agent 的 Skill、命令行工具或 MCP 服务需要 API Key 等自定义值时，请使用 [Agent 环境变量](../worker-env/)。

## 查找设置

系统配置按功能分组显示。你可以搜索设置名称或说明，也可以打开一个分组后集中查看相关选项。

列表中的设置分为三类：

- **可编辑**：可以直接打开并修改。
- **只读**：用于显示当前状态，不能在此修改。
- **由其他页面管理**：选择“前往管理”后，在对应功能页面中修改。

设置名称是稳定的配置键。说明文字会告诉你它控制什么，以及数值使用的单位。

## 理解作用范围和当前来源

系统配置页修改的是实例级覆盖值。表中标为“实例或单个 Agent”的键还允许所属功能为特定 Agent 保存覆盖值，但不能在这个页面选择 Agent。

当这些设置用于某个 Agent 时，系统会依次读取：

1. 当前 Agent 的覆盖值；
2. 实例级覆盖值；
3. 当前版本内置的默认值。

系统配置列表显示实例覆盖值或版本默认值。恢复默认值会删除实例级覆盖；没有单个 Agent 覆盖时，所有 Agent 都会重新使用当前版本的默认值。

## 修改设置

1. 打开目标设置或设置分组。
2. 阅读字段说明，确认作用范围和单位。
3. 修改需要的值并保存。
4. 回到列表，确认该项显示为已覆盖。

部分常用设置有专门的表单。其他高级设置使用 JSON 编辑器；修改前请保留原有字段结构，不要删除不了解的字段。

大多数修改会在后续工作中生效。页面若明确提示“下次启动生效”，需要在合适的时间重启控制面。

## 恢复默认值

如果不再需要自定义值，打开该设置并选择“恢复默认值”。这会删除当前实例保存的覆盖值，让系统重新使用该版本声明的默认配置。

恢复默认值不等于填入一个看起来相同的数值。将来默认配置发生变化时，前者会随版本更新，手工填写的值则会继续保持不变。

## 当前内置的 AppConfigure 键

下面列出 Ankole 当前内置的 AppConfigure 键。Control Plane Plugin 可以注册更多键，实际列表以当前实例的**系统配置**页面为准。

### Agent 运行

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `ai_agent.max_iterations` | 实例或单个 Agent | 单个 Agent 回合允许进行的模型迭代次数 |
| `ai_agent.max_output_tokens` | 实例或单个 Agent | 单次模型响应的输出 token 上限 |
| `ai_agent.inactivity_timeout_ms` | 实例或单个 Agent | 模型或 Provider 无响应多久后结束当前回合 |
| `ai_agent.library.agent_plugin_defaults` | 实例 | Agent Plugin 的默认启用状态 |
| `ai_agent.library.skill_defaults` | 实例 | Skill 的默认启用状态 |

### Brain

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `brain.enabled` | 实例 | 启用 Brain 的检索、学习和维护；关闭后仍保留已经存储的知识 |
| `brain.embedding_model` | 实例 | 向量检索使用的 Provider、模型和维度；留空会停用向量检索 |
| `brain.rerank_model` | 实例 | 搜索结果重排使用的 Provider 和模型；留空会保留融合后的顺序 |
| `brain.web_fetch_model` | 实例 | 从 URL Source 学习时使用的 Provider 和模型；留空会停止这类学习 |
| `brain.extraction_model` | 实例 | 从 Signal 会话和 Source 中提取知识的模型；留空会停止相关学习任务 |
| `brain.dreaming_model` | 实例 | 汇总知识并发现待人工复核矛盾的模型；留空会跳过依赖模型的维护任务 |
| `brain.search_tokenizer` | 实例 | BM25 分词器：`icu`、`jieba`、`lindera_japanese` 或 `lindera_korean`；修改后需要重建 BM25 索引 |
| `brain.chunking` | 实例 | Source 分块大小、重叠量和输入上限 |
| `brain.forgetting` | 实例 | 各类知识的衰减半衰期和软删除清理间隔 |
| `brain.dreaming_task_cron` | 实例 | 定期汇总知识的执行计划 |
| `brain.self_healing_task_cron` | 实例 | 重建过期分块、embedding 和搜索索引投影的执行计划 |
| `brain.signal_channel_batch_idle_time` | 实例 | 待处理聊天消息进入学习前的空闲秒数；会话结束也会触发学习 |
| `brain.skill_learning_enabled` | 实例 | 启用 Skill lesson 的学习和交付；关闭后会保留已经存储的 lesson，但不再提供 |
| `brain.skill_learning_reflection_threshold` | 实例 | 单个 Agent 触发一次 Skill lesson 反思前需要积累的未消费 Signal Job 数量；最小值为 `2` |

[Brain](../brain/) 说明知识行为和模型要求；[Skill lesson](../skill-lessons/) 说明 Brain 会随 Skill 提供哪些经验。

### AI Gateway 与可观测性

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `ai_gateway.compaction` | 实例 | 对话历史自动压缩策略 |
| `observability.traces.enabled` | 实例 | 是否在下次控制面启动时启用进程级 OpenTelemetry 导出 |
| `observability.traces.provider` | 实例 | `langfuse`、`langsmith` 或通用 `opentelemetry` trace 的语义投影 |
| `observability.traces.otlp_endpoint` | 实例 | 可选 trace 使用的基础 OTLP/HTTP endpoint |
| `observability.traces.otlp_headers` | 实例 | 可选 trace 使用的加密认证请求头 |

Langfuse、LangSmith、VictoriaTraces 和其他 OTLP/HTTP 接收端的配置方法见 [LLM 可观测性](../llm-observability/)。

### 身份、插件和实例默认值

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `principals.identity_providers.active` | 实例，只读 | 当前可用于管理员登录的身份源；由身份源提供商页面管理 |
| `principals.identity_providers.directory_full_sync_interval_hours` | 实例 | 企业通讯录和组织架构的全量同步间隔 |
| `plugins.enabled_ids` | 实例 | 下次启动时启用的 Control Plane Plugin |
| `system.timezone` | 实例 | 计划任务等控制面功能使用的默认时区 |
| `i18n.default_locale` | 实例 | Ankole 界面的默认语言 |

### Worker、网页读取和安全

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `runtime_fabric.worker_auth_key` | 实例，只读 | 控制面与 Worker 之间的认证密钥；由系统生成和维护 |
| `agent_computer.background_agent_job.max_turns_per_worker` | 实例 | 每个 Worker 最多同时承载的后台 Agent Job 回合数 |
| `worker.rendered_fetch_idle_ttl_ms` | 实例或单个 Agent | `web_fetch` 内置渲染回退的空闲保留时间 |
| `security.ssrf_filter` | 实例或单个 Agent | 是否拒绝模型发起的私网、环回、链路本地和 CGNAT 地址访问 |

无论该开关是否启用，云服务元数据地址都会被拒绝。

### 首次设置状态

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `setup.bootstrap_activation_code` | 实例，只读 | 首次设置页面使用的临时激活码 |
| `setup.completed` | 实例，只读 | 当前实例是否已经完成首次设置 |

这两个键由首次设置流程维护。需要查看激活码时，运行 `kit show bootstrap-activation-code`，不要在系统配置页手工修改。

## 加密设置

含凭据的设置会加密保存，并在列表和编辑页中以掩码显示。编辑时保留掩码不会改变原值；输入新内容并保存会替换原值。

只有核对现有值确实有必要时才使用“显示内容”。不要把显示出来的凭据复制到聊天消息、截图或工单中。
