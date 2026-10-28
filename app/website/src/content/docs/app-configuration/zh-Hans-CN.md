---
title: 系统配置
description: 在 Console 中管理 Ankole 的 AppConfigure 运行时设置，并查阅内置配置键。
section: User guide
order: 43
---

站点管理员通过 **Console → 系统配置**管理站点默认值、空间策略与共享运行参数。空间管理员继续使用 Pod 设置中已有的管理权限。

## 查找配置与选择范围

编辑前先选择**站点配置与默认值**或**当前空间覆盖**。页面始终显示数据空间名称。站点默认值影响所有未设置覆盖的空间，不代表空间参数的强制上限。

默认使用**按任务分组**视图，相关参数在同一表单中编辑，列表显示启停、覆盖与生效状态。**只读键值注册表**展示所有已注册键与动态规则，注明作用域、值来源、加密状态和管理入口。搜索可以命中组合表单内部字段及旧键名，并打开、定位相应字段；具名管理链接可直达对应 Console 页面和 Tab。

站点级键按“已存站点值 → 代码默认值”解析。租户级键按“实际支持的 Agent 覆盖 → 空间覆盖 → 站点默认 → 代码默认”解析。Pod 级键只读取空间值和代码默认值。五个实际使用 Agent 覆盖的键提供只读查询，不提供 Agent 覆盖写入口。

## 修改与重置

在一个明确范围内编辑，确认单位后保存。组合任务整体提交，任一字段校验失败时整组不变，草稿保留。密钥默认掩码展示，需要明确操作才会解密。重置确认框直接显示当前值、移除覆盖后的实际值与来源。即使覆盖值等于默认值，删除覆盖与手动保存同值仍有区别：后者会继续保持独立覆盖。

时间字段支持可读单位换算，存储单位保持不变。输出上限区分“不显式限制”（`null`）和具体数值，无响应超时可显式关闭（`0`）。缩短删除保留期时，表单会说明永久清理后无法恢复的影响。

Trace 和 Control Plane Plugin 的“待重启”状态会保留到服务进程与已存配置一致。Brain 后台 Tick 每分钟检查共享 BM25 索引，并在分词器变化时重建；维护可能暂时影响检索或阻塞写入。失败时可查看 Brain 健康页与服务端 Tick 日志。

SMTP 表单可使用当前草稿试发，不修改正式邮件配置，也不创建验证码。未输入替代密码时保留已存密码。试发成功表示传输服务已接受邮件；修改草稿后，原试发结果会标记失效。SaaS 的 Turnstile 启停开关可在保留两项 Key 的情况下暂停挑战校验。

## 配置与环境变量

AppConfigure 将产品参数保存在 PostgreSQL，多数修改影响后续任务。[部署环境变量](../environment-variables/)提供启动所需基础设施参数；工具使用的自定义凭据请放入 [Agent 环境变量](../worker-env/)。

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
| `background_agent_jobs.max_running_per_agent` | 租户 | 单个 Agent 允许并发运行的后台 Agent 任务上限；默认 `3`，有效范围为 `1`–`64` |
| `automation_jobs.max_running_per_agent` | 租户 | 单个 Agent 允许并发运行的自动化脚本上限；默认 `10`，有效范围为 `1`–`64` |

### Pod、Base 与 Applet

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `pod.allow_external_guests` | 租户 | 是否允许受邀外部访客访问共享的 Pod 页面；默认 `true` |
| `pod.applet.limits` | 租户 | Applet（小应用）运行限制（默认 `timeout_ms: 60000`、`heap_mb: 128`） |
| `pod.base.limits` | 租户 | Base 查询与记录限制（默认 `query_rows: 1000`、`record_bytes: 1000000`、`group_count: 1000`、`statement_timeout_ms: 5000`） |
| `pod.trash_retention_days` | 租户 | 已删除页面在自动彻底清理前保留的天数（正整数，默认 `30`） |
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
| `brain.forgetting` | 租户 | 各类记忆的时间衰减半衰期 |
| `brain.soft_delete_retention_hours` | 租户 | 已软删除对象在 Dreaming 永久清理前的保留小时数，默认 `72` |
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
| `authn.email.send_limits` | 站点 | 共享发送时间窗口，以及邮箱、请求来源与 SMTP 渠道上限 |
| `authn.email.failure_limits` | 站点 | 共享验证失败时间窗口，以及邮箱与请求来源的失败上限 |
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
| `i18n.default_locale` | Pod | 当前 Pod 空间的界面、通知邮件与 Agent 消息默认语言；空间管理员也可在 **Pod 设置**中直接修改 |

### Worker、网页读取和安全

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `runtime_fabric.worker_auth_key` | 站点，只读 | 控制面首次启动时生成的实例标识密钥；用于派生飞书（Lark）配置名称，并非 Worker 鉴权凭据 |
| `agent_workers.ready_timeout_seconds` | 站点 | Worker 实例处于未就绪状态的最长容忍秒数，超时后将挂载新缓存盘重建实例；默认 `600`（10 分钟） |
| `agent_workers.rendered_fetch_idle_ttl_ms` | 租户 | `web_fetch` 内置浏览器渲染回退实例的空闲保留毫秒数 |
| `security.ssrf_filter` | 站点 | 是否拦截由模型发起的对私网、环回地址、链路本地地址及 CGNAT 地址段的网络访问 |

无论 `security.ssrf_filter` 是否开启，云厂商实例元数据地址始终会被强制拦截。

`agent_workers.ready_timeout_seconds` 专门控制已拉起但迟迟未能就绪的实例自愈重建；而正常运行后的空闲实例回收时长，则在 Worker Provider 的 YAML 配置中通过 `idleReleaseAfter` 设定，详见 [工作节点](../worker-management/)。

### 首次设置状态

| 配置键 | 作用范围 | 用途 |
|---|---|---|
| `setup.bootstrap_activation_code` | 站点，只读 | 首次初始化页面校验使用的临时激活码 |
| `setup.completed` | 站点，只读 | 标记当前实例是否已完成首次初始化 |

这两个状态键由初始化向导自动维护。如需查看初始化激活码，请在服务端执行 `kit show bootstrap-activation-code`，切勿尝试在系统配置页手动更改。

## 加密设置

包含敏感凭据的配置项在落盘时自动加密，并在列表页和编辑表单中脱敏掩码展示。编辑时若保留原有掩码不变，系统会继续沿用已保存的原值；只有输入新内容并点击保存，才会替换原值。

请仅在确有必要核对当前配置时点击“显示内容”，且切勿将明文凭据粘贴到聊天群、截图或公开工单中。
