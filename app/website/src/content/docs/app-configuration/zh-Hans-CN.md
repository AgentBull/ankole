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

[部署环境变量](../environment-variables/)用于启动控制面和 PostgreSQL，并配置 Worker 后端。修改后需要重启相应进程。

Agent 的 Skill、命令行工具或 MCP 服务需要 API Key 等自定义值时，请使用 [Agent 环境变量](../worker-env/)。

## 查找设置

系统配置按功能分组显示。你可以搜索设置名称或说明，也可以打开一个分组后集中查看相关选项。

列表中的设置分为三类：

- **可编辑**：可以直接打开并修改。
- **只读**：用于显示当前状态，不能在此修改。
- **由其他页面管理**：选择“前往管理”后，在对应功能页面中修改。

设置名称是稳定的配置键。说明文字会告诉你它控制什么，以及数值使用的单位。

## 理解作用范围和当前来源

配置键分为**站点**与**租户**作用域。站点键控制共享基础设施；租户键控制所选租户的行为。Console 分别展示站点默认值与租户覆盖，不支持 Agent 覆盖。

站点键先读取已存值，再使用版本默认值。租户键依次读取租户覆盖、同名键的站点默认值、版本默认值。“恢复默认值”删除所选作用域的覆盖；“来源”列说明当前生效值来自哪里。

## 修改设置

1. 打开目标设置或设置分组。
2. 阅读字段说明，确认作用范围和单位。
3. 修改需要的值并保存。
4. 回到列表，确认该项显示为已覆盖。

部分常用设置有专门的表单。其他高级设置使用 JSON 编辑器；修改前请保留原有字段结构，不要删除不了解的字段。

大多数修改会在后续工作中生效。页面若明确提示“下次启动生效”，需要在合适的时间重启控制面。

## 恢复默认值

如果不再需要自定义值，打开该设置并选择“恢复默认值”。这会删除所选作用域保存的覆盖值，让系统重新使用该版本声明的默认配置。

恢复默认值不等于填入一个看起来相同的数值。将来默认配置发生变化时，前者会随版本更新，手工填写的值则会继续保持不变。

## 当前内置的 AppConfigure 键

下面列出 Ankole 当前内置的 AppConfigure 键。Control Plane Plugin 可以注册更多键，实际列表以当前实例的**系统配置**页面为准。

### Agent 运行

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `ai_agent.max_iterations` | 租户 | 单个 Agent 回合允许进行的模型迭代次数 |
| `ai_agent.max_output_tokens` | 租户 | 单次模型响应的输出 token 上限 |
| `ai_agent.inactivity_timeout_ms` | 租户 | 模型或 Provider 无响应多久后结束当前回合 |
| `ai_agent.library.agent_plugin_defaults` | 租户 | Agent Plugin 的默认启用状态 |
| `ai_agent.library.skill_defaults` | 租户 | Skill 的默认启用状态 |
| `agent_computer.background_agent_job.max_running_per_agent` | 租户 | 单个 Agent 允许并发运行的后台 Agent 任务上限；默认 `3`，有效范围为 `1`–`64` |
| `automation_jobs.max_running_per_agent` | 租户 | 单个 Agent 允许并发运行的自动化脚本上限；默认 `10`，有效范围为 `1`–`64` |

### Pod、Base 与 Applet

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `pod.allow_external_guests` | 租户 | 是否允许受邀外部访客访问共享的 Pod 页面；默认 `true` |
| `pod.applet.limits` | 租户 | Applet（小应用）调用限制（默认 `timeout_ms: 60000`、`heap_mb: 128`） |
| `pod.applet.ai_agent_uid` | 租户 | 承载 Applet（小应用）`ctx.ai` 调用模型档案与用量的启用状态 Agent；留空时停用 Applet AI |
| `pod.base.limits` | 租户 | Base 查询与记录限制（默认 `query_rows: 1000`、`record_bytes: 1000000`、`group_count: 1000`、`statement_timeout_ms: 5000`） |
| `pod.trash_retention_days` | 租户 | 已删除页面自动彻底清理前的保留正整数天数（默认 `30`），或设为 `"unlimited"` 以无限期保留、不自动清理 |
| `pod.ot_replay_window` | 租户 | 为 OT 重放保留的最近文档变更批次数；默认 `1000` |

### Workflow

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `workflow.max_concurrency_per_run` | 租户 | 单次 Workflow 可以申请的任务并发上限；默认 `8`，有效范围为 `1`–`32` |
| `workflow.max_running_per_agent` | 租户 | 单个 Agent 的所有 Workflow 中正在运行的任务总上限；默认 `8`，有效范围为 `1`–`64` |
| `workflow.max_agent_calls_per_run` | 租户 | 单次 Workflow 可以创建的子 Agent 调用上限；默认 `32`，有效范围为 `1`–`1,024` |

这些限制影响后续 Workflow 工作。单次运行可以申请更低的并发数或调用数，但不能抬高租户上限。任务行为和其他大小限制见 [Workflow](../workflows/)。

### Brain

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `brain.enabled` | 租户 | 启用 Brain 的检索、学习和维护；关闭后仍保留已经存储的知识 |
| `brain.maintainer_agent_uid` | 租户 | 负责维护 Brain 的活跃 Agent；Brain 的所有模型调用都以该 Agent 的身份执行，并把用量归到该 Agent；停用后会停止这些调用和 URL Source 抓取，直到重新启用或更换 Agent；在 Agent 页面编辑对应的 `light`、`heavy` 和 `web_fetch` profile |
| `brain.embedding_model` | 站点 | 向量检索使用的 Provider、模型和维度；留空会停用向量检索 |
| `brain.rerank_model` | 租户 | 搜索结果重排使用的 Provider 和模型；留空会保留融合后的顺序 |
| `brain.search_tokenizer` | 站点 | BM25 分词器：`icu`、`jieba`、`lindera_japanese` 或 `lindera_korean`；修改后需要重建 BM25 索引 |
| `brain.chunking` | 租户 | Source 分块大小、重叠量和输入上限 |
| `brain.forgetting` | 租户 | 各类知识的衰减半衰期和软删除清理间隔 |
| `brain.dreaming_task_cron` | 租户 | 定期汇总知识的执行计划 |
| `brain.self_healing_task_cron` | 租户 | 重建过期分块、embedding 和搜索索引投影的执行计划 |
| `brain.signal_channel_batch_idle_time` | 租户 | 待处理聊天消息进入学习前的空闲秒数；会话结束也会触发学习 |
| `brain.skill_learning_enabled` | 租户 | 启用 Skill lesson 的学习和交付；关闭后会保留已经存储的 lesson，但不再提供 |
| `brain.skill_learning_reflection_threshold` | 租户 | 单个 Agent 触发一次 Skill lesson 反思前需要积累的未消费 Signal Job 数量；最小值为 `2` |

[Brain](../brain/) 说明知识行为和模型要求；[Skill lesson](../skill-lessons/) 说明 Brain 会随 Skill 提供哪些经验。

### AI Gateway 与可观测性

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `ai_gateway.compaction` | 站点 | 对话历史自动压缩策略 |
| `observability.traces.enabled` | 站点 | 是否在下次控制面启动时启用进程级 OpenTelemetry 导出 |
| `observability.traces.provider` | 站点 | `langfuse`、`langsmith` 或通用 `opentelemetry` trace 的语义投影 |
| `observability.traces.otlp_endpoint` | 站点 | 可选 trace 使用的基础 OTLP/HTTP endpoint |
| `observability.traces.otlp_headers` | 站点 | 可选 trace 使用的加密认证请求头 |

Langfuse、LangSmith、VictoriaTraces 和其他 OTLP/HTTP 接收端的配置方法见 [LLM 可观测性](../llm-observability/)。

### 免密邮箱验证码（Email OTP）与 Pod 登录策略

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `authn.email.mail` | 站点，加密 | 用于免密 Email OTP 登录的站点 SMTP 发信配置（`server`、`from`、`port`、`ssl` 及可选认证凭据）；留空时停用 Email OTP |
| `authn.email.code_ttl_seconds` | 站点 | 邮箱验证码有效秒数；默认 `600` |
| `authn.email.send_window_seconds` | 站点 | 发送验证码限流窗口秒数；默认 `60` |
| `authn.email.send_email_limit` | 站点 | 单个收件邮箱在发送窗口内最多发送次数；默认 `3` |
| `authn.email.send_source_limit` | 站点 | 单个来源地址在发送窗口内最多发送次数；默认 `20` |
| `authn.email.send_channel_limit` | 站点 | 整个发信通道在发送窗口内最多发送次数；默认 `100` |
| `authn.email.failure_window_seconds` | 站点 | 验证码校验失败限流窗口秒数；默认 `600` |
| `authn.email.failure_email_limit` | 站点 | 单个邮箱在失败窗口内最多允许失败次数；默认 `10` |
| `authn.email.failure_source_limit` | 站点 | 单个来源地址在失败窗口内最多允许失败次数；默认 `100` |
| `principals.pod_login_policy` | 租户，由其他页面管理 | Pod 成员登录与邀请策略（`allow_email_otp`、`allow_member_credential_change`、`allowed_email_domains`、`require_sso_for_members`、`allow_invite_links`）；由 Pod 设置管理 |

### 身份、插件、特性开关和租户默认值

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `principals.identity_providers.active` | 租户，只读 | 当前用于认证 Pod 工作区成员和管理员的已启用租户身份源；由 Pod 设置和身份源提供商页面管理 |
| `principals.identity_providers.directory_full_sync_interval_minutes` | 租户 | 企业通讯录和组织架构的全量同步间隔 |
| `tenants.privileged_tenant_id` | 站点，只读 | 拥有管理本站点的 `siteadmin` 权限组的特权租户 ID |
| `plugins.enabled_ids` | 站点，由其他页面管理 | 下次启动时启用的 `:optional` Control Plane Plugin 列表；`:always` 插件随构建始终保持启用 |
| `features.<flag>` | 站点 | 支撑 OpenFeature 的特性可用性策略（`{enabled, percent, targets}`，`Ankole.Features.Config`） |
| `signals.show_dead_letter_error_details` | 站点 | 发送到会话的死信通知中是否附带经截断与脱敏的 Session 回合错误详情；默认 `false` |
| `system.timezone` | 租户 | 计划任务等控制面功能使用的默认时区 |
| `i18n.default_locale` | 租户 | Ankole 界面的默认语言 |

### Worker、网页读取和安全

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `runtime_fabric.worker_auth_key` | 站点，只读 | 控制面首次启动时生成的安装密钥；用于命名 Lark profile，不是 Worker 凭据 |
| `agent_computer.worker.ready_timeout` | 站点 | Worker 可以保持未就绪多少秒，超过后用新的缓存盘重建；默认 `600`（10 分钟） |
| `worker.rendered_fetch_idle_ttl_ms` | 租户 | `web_fetch` 内置渲染回退的空闲保留时间 |
| `security.ssrf_filter` | 站点 | 是否拒绝模型发起的私网、环回、链路本地和 CGNAT 地址访问 |

无论该开关是否启用，云服务元数据地址都会被拒绝。

`agent_computer.worker.ready_timeout` 控制已观察到但未就绪的实例恢复。空闲回收在 provider YAML 中用 `idleReleaseAfter` 设置，见 [工作节点](../worker-management/)。

### 首次设置状态

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `setup.bootstrap_activation_code` | 站点，只读 | 首次设置页面使用的临时激活码 |
| `setup.completed` | 站点，只读 | 当前实例是否已经完成首次设置 |

这两个键由首次设置流程维护。需要查看激活码时，运行 `kit show bootstrap-activation-code`，不要在系统配置页手工修改。

## 加密设置

含凭据的设置会加密保存，并在列表和编辑页中以掩码显示。编辑时保留掩码不会改变原值；输入新内容并保存会替换原值。

只有核对现有值确实有必要时才使用“显示内容”。不要把显示出来的凭据复制到聊天消息、截图或工单中。
