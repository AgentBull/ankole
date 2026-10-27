---
title: 系统配置
description: 在 Console 中管理 Ankole 的 AppConfigure 运行时设置，并查阅内置配置键。
section: User guide
order: 43
---

**Console → 系统配置**集中管理可在实例运行期间动态调整的参数，例如对话历史压缩策略、Agent 运行并发上限、通讯录同步周期以及插件开关。

模型提供商、身份源提供商、聊天渠道和环境变量各有专属管理页面，无需在此重复配置。

## 系统配置与环境变量的区别

AppConfigure 配置项保存在 PostgreSQL 数据库中，用于控制 Ankole 运行期间的产品行为。绝大多数修改保存后即在后续任务中自动生效，无需重新部署实例。

[部署环境变量](../environment-variables/)则用于引导控制面与 PostgreSQL 启动，并配置底层 Worker 运行后端；修改这类变量后必须重启对应进程才能生效。

如果某个 Agent 的 Skill、命令行工具或 MCP 服务需要读取第三方 API Key 等自定义参数，请前往 [Agent 环境变量](../worker-env/)配置。

## 查找设置

系统配置页面按功能模块分组展示。你可以直接按配置键名或用途说明搜索，也可以展开具体分组集中查看相关选项。

列表中的配置项分为以下三类：

- **可编辑**：可直接在当前页面点开并修改。
- **只读**：仅用于展示当前系统状态，不支持在此手工修改。
- **由其他页面管理**：点击“前往管理”即可跳转到对应的功能页面完成配置。

每项配置的名称即为其稳定的配置键名，下方说明会标明该项控制的具体行为与数值单位。

## 理解作用范围和当前来源

配置键按作用范围分为**站点**与**租户**两级：站点级配置控制全局共享的基础设施，租户级配置控制当前所选租户的产品行为。Console 会分别展示站点默认值与租户覆盖值，不支持按单个 Agent 覆盖。

解析生效值时，站点级配置优先采用数据库中已保存的值，未保存时回退到当前版本的内置默认值；租户级配置则按“租户覆盖值 → 同名键的站点默认值 → 版本内置默认值”的顺序依次查找。点击“恢复默认值”会清除所选作用域下保存的覆盖记录；列表中的“来源”列会直观标明当前生效值的具体出处。

## 修改设置

1. 点开目标配置项或所在分组。
2. 阅读字段说明，确认其作用范围与数值单位。
3. 填入新值并点击保存。
4. 返回列表，确认该配置项的状态已更新为“已覆盖”。

常用配置项配有专用可视化表单，其余高阶配置则通过 JSON 编辑器修改；编辑 JSON 时请保持原有字段结构完整，切勿随意删改含义不明的字段。

绝大多数修改会在新启动的任务中立即生效；若页面明确提示“下次启动生效”，请安排合适窗口重启控制面进程。

## 恢复默认值

不再需要自定义配置时，打开对应配置项并点击“恢复默认值”，即可删除当前作用域保存的覆盖记录，让系统重新沿用当前版本声明的默认配置。

请注意，“恢复默认值”与“手动填入一个和当前默认值相同的数字”并不等价：日后升级新版本若调整了官方默认配置，前者会自动跟随新版本更新，而手动写入的覆盖值则会一直固定不变。

## 当前内置的 AppConfigure 键

下表列出 Ankole 当前内置的 AppConfigure 配置键。Control Plane Plugin 还可注册更多扩展配置键，完整列表请以当前实例的**系统配置**页面为准。

### Agent 运行

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `ai_agent.max_iterations` | 租户 | 单个 Agent 回合内允许执行的模型迭代最大轮数 |
| `ai_agent.max_output_tokens` | 租户 | 单次模型响应允许生成的最大输出 Token 数 |
| `ai_agent.inactivity_timeout_ms` | 租户 | 模型或上游 Provider 持续无响应多少毫秒后终止当前回合 |
| `ai_agent.library.agent_plugin_defaults` | 租户 | Agent Plugin 的默认启用状态映射 |
| `ai_agent.library.skill_defaults` | 租户 | Skill 的默认启用状态映射 |
| `agent_computer.background_agent_job.max_running_per_agent` | 租户 | 单个 Agent 允许并发运行的后台 Agent 任务上限；默认 `3`，有效范围为 `1`–`64` |
| `automation_jobs.max_running_per_agent` | 租户 | 单个 Agent 允许并发运行的自动化脚本上限；默认 `10`，有效范围为 `1`–`64` |

### Pod、Base 与 Applet

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `pod.allow_external_guests` | 租户 | 是否允许受邀外部访客访问共享的 Pod 页面；默认 `true` |
| `pod.applet.limits` | 租户 | Applet（小应用）运行限制（默认 `timeout_ms: 60000`、`heap_mb: 128`） |
| `pod.base.limits` | 租户 | Base 查询与记录限制（默认 `query_rows: 1000`、`record_bytes: 1000000`、`group_count: 1000`、`statement_timeout_ms: 5000`） |
| `pod.trash_retention_days` | 租户 | 已删除页面在自动彻底清理前保留的天数（正整数，默认 `30`）；设为 `"unlimited"` 则无限期保留、不自动清理 |
| `pod.ot_replay_window` | 租户 | 为协同文档 OT 重放保留的最近变更批次数；默认 `1000` |

### Workflow

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `workflow.max_concurrency_per_run` | 租户 | 单次 Workflow 运行可申请的任务并发上限；默认 `8`，有效范围为 `1`–`32` |
| `workflow.max_running_per_agent` | 租户 | 单个 Agent 名下所有 Workflow 合计正在运行的任务总上限；默认 `8`，有效范围为 `1`–`64` |
| `workflow.max_agent_calls_per_run` | 租户 | 单次 Workflow 运行允许发起的子 Agent 调用上限；默认 `32`，有效范围为 `1`–`1,024` |

修改上述参数会影响后续启动的 Workflow。单次运行可以申请更低的并发度或调用次数，但无法突破租户上限。更多执行细节与体积限制请参阅 [Workflow](../workflows/)。

### Brain

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `brain.enabled` | 租户 | 是否启用 Brain 的知识检索、自动学习与后台维护；关闭后已存储的知识仍会保留 |
| `brain.maintainer_agent_uid` | 租户 | 指定负责维护 Brain 的启用态 Agent。Brain 的全部模型调用均以该 Agent 身份发起并将用量计入其名下；若该 Agent 被停用，Brain 模型调用与 URL Source 抓取将暂停，直至重新启用或更换 Agent。请在对应 Agent 页面配置其 `light`、`heavy` 与 `web_fetch` 模型档案 |
| `brain.embedding_model` | 站点 | 向量检索使用的 Provider、模型与向量维度；留空将停用向量检索 |
| `brain.rerank_model` | 租户 | 搜索结果重排序使用的 Provider 与模型；留空则直接保留多路召回融合后的排序 |
| `brain.search_tokenizer` | 站点 | BM25 全文检索分词器：`icu`、`jieba`、`lindera_japanese` 或 `lindera_korean`；修改后需重建 BM25 索引 |
| `brain.chunking` | 租户 | Source 文档切片大小、相邻重叠字数与输入长度上限 |
| `brain.forgetting` | 租户 | 各类记忆的时间衰减半衰期与软删除清理周期 |
| `brain.dreaming_task_cron` | 租户 | 后台定期归纳整理知识（Dreaming）的 Cron 计划 |
| `brain.self_healing_task_cron` | 租户 | 定期修复过期文档分块、向量嵌入与搜索索引投影的自愈 Cron 计划 |
| `brain.signal_channel_batch_idle_time` | 租户 | 待学习的聊天消息批次在进入提炼流程前需静置的空闲秒数（会话结束时也会立即触发学习） |
| `brain.skill_learning_enabled` | 租户 | 是否开启技能教训（Skill Lesson）的自动提炼与投递；关闭后已保存的教训仍会保留，但执行时暂不注入 |
| `brain.skill_learning_reflection_threshold` | 租户 | 单个 Agent 触发一次技能教训反思前需累计的未消费 Signal Job 数量；最小值为 `2` |

关于知识组织方式与模型配置要求，请参阅 [Brain](../brain/)；关于随 Skill 动态注入的过程经验机制，请参阅[技能教训](../skill-lessons/)。

### AI Gateway 与可观测性

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `ai_gateway.compaction` | 站点 | 对话历史自动压缩策略 |
| `observability.traces.enabled` | 站点 | 下次启动控制面时是否开启进程级 OpenTelemetry 追踪导出 |
| `observability.traces.provider` | 站点 | 追踪数据的语义投影格式：`langfuse`、`langsmith` 或通用 `opentelemetry` |
| `observability.traces.otlp_endpoint` | 站点 | 启用追踪导出时使用的基础 OTLP/HTTP 端点地址 |
| `observability.traces.otlp_headers` | 站点 | 启用追踪导出时使用的加密认证请求头 |

对接 Langfuse、LangSmith、VictoriaTraces 及其他 OTLP/HTTP 接收端的完整配置步骤，请参阅 [LLM 可观测性](../llm-observability/)。

### 免密邮箱验证码（Email OTP）与 Pod 登录策略

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `authn.email.mail` | 站点，加密 | 用于免密 Email OTP 登录的站点级 SMTP 发信配置（含 `server`、`from`、`port`、`ssl` 及可选认证凭据）；留空时停用 Email OTP |
| `authn.email.code_ttl_seconds` | 站点 | 邮箱验证码的有效秒数；默认 `600` |
| `authn.email.send_window_seconds` | 站点 | 验证码发送限流统计窗口秒数；默认 `60` |
| `authn.email.send_email_limit` | 站点 | 单个收件邮箱在发送窗口内的最大发送次数；默认 `3` |
| `authn.email.send_source_limit` | 站点 | 单个客户端来源地址在发送窗口内的最大发送次数；默认 `20` |
| `authn.email.send_channel_limit` | 站点 | 整个发信通道在发送窗口内的最大发送总次数；默认 `100` |
| `authn.email.failure_window_seconds` | 站点 | 验证码核验失败的限流统计窗口秒数；默认 `600` |
| `authn.email.failure_email_limit` | 站点 | 单个邮箱在失败窗口内允许的最大连续失败次数；默认 `10` |
| `authn.email.failure_source_limit` | 站点 | 单个客户端来源地址在失败窗口内允许的最大失败次数；默认 `100` |
| `principals.pod_login_policy` | 租户，由其他页面管理 | Pod 工作区成员登录与邀请策略（`allow_email_otp`、`allow_member_credential_change`、`allowed_email_domains`、`require_sso_for_members`、`allow_invite_links`）；在 **Pod 设置**中管理 |

### 身份、插件、特性开关和租户默认值

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `principals.identity_providers.active` | 租户，只读 | 当前用于认证 Pod 工作区成员与管理员的已启用租户身份源；由 **Pod 设置**和**身份源提供商**页面维护 |
| `principals.identity_providers.directory_full_sync_interval_minutes` | 租户 | 企业通讯录与组织架构的全量同步间隔（分钟） |
| `tenants.privileged_tenant_id` | 站点，只读 | 持有 `siteadmin` 站点管理权限组的特权租户 ID |
| `plugins.enabled_ids` | 站点，由其他页面管理 | 下次启动控制面时启用的 `:optional` 可选 Control Plane Plugin 列表（`:always` 插件随构建常驻启用） |
| `features.<flag>` | 站点 | 驱动 OpenFeature 的特性灰度开关策略（`{enabled, percent, targets}`，`Ankole.Features.Config`） |
| `signals.show_dead_letter_error_details` | 站点 | 向会话发送死信通知时，是否附带经截断与脱敏处理的 Session 回合报错详情；默认 `false` |
| `system.timezone` | 租户 | 定时计划任务等控制面功能使用的默认时区 |
| `i18n.default_locale` | 租户 | Ankole 界面默认语言 |

### Worker、网页读取和安全

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `runtime_fabric.worker_auth_key` | 站点，只读 | 控制面首次启动时生成的实例标识密钥；用于派生飞书（Lark）配置名称，并非 Worker 鉴权凭据 |
| `agent_computer.worker.ready_timeout` | 站点 | Worker 实例处于未就绪状态的最长容忍秒数，超时后将挂载新缓存盘重建实例；默认 `600`（10 分钟） |
| `worker.rendered_fetch_idle_ttl_ms` | 租户 | `web_fetch` 内置浏览器渲染回退实例的空闲保留毫秒数 |
| `security.ssrf_filter` | 站点 | 是否拦截由模型发起的对私网、环回地址、链路本地地址及 CGNAT 地址段的网络访问 |

无论 `security.ssrf_filter` 是否开启，云厂商实例元数据地址始终会被强制拦截。

`agent_computer.worker.ready_timeout` 专门控制已拉起但迟迟未能就绪的实例自愈重建；而正常运行后的空闲实例回收时长，则在 Worker Provider 的 YAML 配置中通过 `idleReleaseAfter` 设定，详见 [工作节点](../worker-management/)。

### 首次设置状态

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `setup.bootstrap_activation_code` | 站点，只读 | 首次初始化页面校验使用的临时激活码 |
| `setup.completed` | 站点，只读 | 标记当前实例是否已完成首次初始化 |

这两个状态键由初始化向导自动维护。如需查看初始化激活码，请在服务端执行 `kit show bootstrap-activation-code`，切勿尝试在系统配置页手动更改。

## 加密设置

包含敏感凭据的配置项在落盘时自动加密，并在列表页和编辑表单中脱敏掩码展示。编辑时若保留原有掩码不变，系统会继续沿用已保存的原值；只有输入新内容并点击保存，才会替换原值。

请仅在确有必要核对当前配置时点击“显示内容”，且切勿将明文凭据粘贴到聊天群、截图或公开工单中。
