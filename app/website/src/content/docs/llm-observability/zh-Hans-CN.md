---
title: LLM 可观测性
description: 按需将跨运行时的 Agent 回合追踪数据（含 AIGateway LLM 语义）通过 OTLP/HTTP 导出至可观测性接收端。
section: User guide
order: 44
---

Ankole 支持通过 OpenTelemetry Protocol（OTLP）HTTP/protobuf 导出 OpenTelemetry 追踪数据（Trace），该功能默认关闭。`observability.traces.provider` 用于指定附加到回合（Turn）根 Span 与 AIGateway LLM Span 上的厂商语义属性——它并非 AIGateway 模型提供商，不负责底层传输实现，也不会过滤其他 OpenTelemetry Span。以下三种导出模式共用同一套进程级 OpenTelemetry SDK 与 OTLP 导出器：

- `langfuse`：补充 Langfuse v4 的 Agent 与 Generation 专属属性。
- `langsmith`：补充 LangSmith 的运行类型（run type）及兼容内容属性。
- `opentelemetry`：仅发送标准 OpenTelemetry、`gen_ai.*` 及 Ankole 自有属性，适用于 VictoriaTraces、Honeycomb、Grafana Cloud 与 OpenTelemetry Collector。

开启导出后，Trace 中会包含模型的输入与输出，也可能记录工具调用的参数与返回结果。导出前，Ankole 会自动剔除已配置的凭证、请求头、通用调用方元数据、加密的推理与工具字段以及内部 `__ankole_*` 字段；同时将内联 `data:` 媒体替换为字节长度，并跳过体积超过 1 MiB 的输入或输出载荷。即便如此，接收端仍须是受信任的系统，并配妥访问控制与数据保留策略。

每次派发的 Agent 回合都会生成一条独立的 Trace。其中根 Span 名为 `turn <事件类型>`，在 Langfuse 中映射为 Agent Observation，记录脱敏后的触发事件与最终回复。主 Agent 的工具调用 Span 与 AIGateway 响应 Span 均挂载在该根节点下；若是后台任务（Background Job），还会额外包含 `codex.turn` 与 Codex 工具 Span。无回合上下文的 AIGateway 直接调用则继续以 `ai_gateway.response` 作为根 Span。Agent Computer 会通过已认证的 Runtime Fabric RPC 通道将 protobuf 格式的 OTLP 批次上报至控制面统一转发，因此接收端凭证只需保存在控制面，不会下发到工作节点。

## 配置 Langfuse

以下步骤与 [Langfuse 原生 OpenTelemetry 指南](https://langfuse.com/integrations/native/opentelemetry)及 [Langfuse v4 迁移检查表](https://langfuse.com/integrations/native/opentelemetry/migration-to-v4)保持一致。

### 前置条件

- 创建 Langfuse 项目，并在 **Settings → API Keys** 中复制项目的 Public Key（`pk-lf-...`）与 Secret Key（`sk-lf-...`）。
- 根据项目所在区域选择对应的基础端点地址：

| 部署环境 | `observability.traces.otlp_endpoint` |
|---|---|
| Langfuse Cloud EU | `https://cloud.langfuse.com/api/public/otel` |
| Langfuse Cloud US | `https://us.cloud.langfuse.com/api/public/otel` |
| Langfuse Cloud Japan | `https://jp.cloud.langfuse.com/api/public/otel` |
| Langfuse Cloud HIPAA | `https://hipaa.cloud.langfuse.com/api/public/otel` |
| 自托管 Langfuse 3.22.0 或更高版本 | `https://<langfuse-host>/api/public/otel` |

填写的端点必须是基础地址，切勿包含 `/v1/traces` 后缀——Ankole 发送请求时会自动追加 `/v1/traces`，并以 `application/x-protobuf` 格式传输。注意，Langfuse 的该端点不接受 OTLP/gRPC 协议。

### 生成 Authorization 值

HTTP Basic Auth 以项目 Public Key 作为用户名、Secret Key 作为密码。运行以下命令生成不含换行符的 Base64 编码字符串：

```bash
printf '%s' 'pk-lf-...:sk-lf-...' | base64 | tr -d '\n'
```

填写认证请求头时，请在编码结果前加上 `Basic ` 前缀；不要将两个独立的 Langfuse 密钥分别直接写入 AppConfigure。

### 写入 AppConfigure

打开 **Console → 系统配置 → LLM 可观测性**，按顺序填写表单：

1. 将 **Trace Provider** 设为 **Langfuse**。
2. 填入上一步选定的基础端点地址。
3. 添加以下两行认证请求头，并将 `<base64-value>` 替换为实际编码值：

   | 请求头名称 | 请求头值 |
   |---|---|
   | `Authorization` | `Basic <base64-value>` |
   | `x-langfuse-ingestion-version` | `4` |

4. 开启 **Trace 导出**并保存。
5. 重启控制面——上述四项配置仅在控制面启动时读取一次。
6. 发送一条普通 Agent 消息或运行一次后台任务，随后打开 Langfuse 项目验证：页面中应出现名为 `turn <事件类型>` 的根级 Agent Observation；主 Agent 的 Trace 下挂载 `tool <名称>` 与 `ai_gateway.response` 子 Span，每次模型响应下包含 `chat <model>` Generation；后台任务还会包含 `codex.turn` 与 Codex 工具 Span；直接调用 AIGateway 的请求仍显示为 `ai_gateway.response` 根节点；提供商原生的上下文压缩调用则会单独显示为 `compact <model>` Generation。

设置请求头 `x-langfuse-ingestion-version: 4` 后，数据将走 Langfuse v4 实时摄取路径；若漏配此请求头，直接上报的数据可能会延迟展示。请求头的值会加密存储在 PostgreSQL 中，保存后在 Console 界面上仅以掩码形式展示。

Langfuse 支持按触发者身份对 Trace 分组，Ankole 按以下规则写入 `user.id`：

- 由可信人工用户直接发起的私聊回合：写入 `principal:<principal_uid>`。
- 群聊回合，或带有来源对话（Conversation）的事件回合：写入 `channel:<conversation_uuid>`。
- 无来源对话、但存在可信人工触发者的回合：写入 `principal:<principal_uid>`。
- 既无可信人工触发者、也无来源对话的回合：省略 `user.id`。

不属于任何回合的 AIGateway 直接调用会写入 `principal:<authenticated_subject_uid>`。Agent 自身的身份信息则记录在 `ankole.principal.uid`、`ankole.principal.type` 以及可筛选的 Trace 元数据中。此外，主 Agent 对话或后台任务的 Codex 会话会映射为 Langfuse Session。

注意，`channel:` 前缀是可观测性传输契约的一部分，后面的值是公开的 Conversation UUID，而非外部聊天平台的频道 ID。

如需在每条 Trace 上标注部署环境与版本号，可在控制面进程中设置可选环境变量 `ANKOLE_ENV`（仅限小写字母、数字、`-` 与 `_`，最长 40 个字符，映射为 Langfuse environment）与 `ANKOLE_VERSION`（映射为 release）。

如需停用导出，将 `observability.traces.enabled` 设为 `false` 并重启控制面即可。Trace 采用尽力而为（best-effort）方式异步发送，Ankole 不为其维护持久化发件箱（outbox）；即便导出失败，也不会影响回合执行或 AIGateway 模型调用的正常结果。

## 配置 LangSmith

以下步骤遵循 [LangSmith OpenTelemetry 官方文档](https://docs.langchain.com/langsmith/trace-with-opentelemetry)与 [LangSmith OpenTelemetry 发布说明](https://www.langchain.com/blog/opentelemetry-langsmith)。Ankole 会按 LangSmith 当前的数据映射规范发送 `langsmith.span.kind`、`gen_ai.prompt`、`gen_ai.completion`、模型名称及 Token 用量属性。

1. 打开 **Console → 系统配置 → LLM 可观测性**，将 **Trace Provider** 设为 **LangSmith**。
2. 根据 LangSmith 所在区域填写基础端点地址（切勿追加 `/v1/traces`）：

   | 部署环境 | `observability.traces.otlp_endpoint` |
   |---|---|
   | GCP US | `https://api.smith.langchain.com/otel` |
   | GCP EU | `https://eu.api.smith.langchain.com/otel` |
   | GCP APAC | `https://apac.api.smith.langchain.com/otel` |
   | AWS US | `https://aws.api.smith.langchain.com/otel` |
   | 自托管 | `https://<langsmith-api-host>/api/v1/otel` |

3. 添加以下认证请求头：

   | 请求头名称 | 请求头值 |
   |---|---|
   | `x-api-key` | `<langsmith-api-key>` |
   | `Langsmith-Project` | `<project-name>` |

   其中 `Langsmith-Project` 为可选项，省略时 Trace 会归入 `default` 项目。当某次 AIGateway 响应归属于特定对话时，`langsmith` 模式会将对话 ID 写入 LangSmith 官方约定的 `langsmith.trace.session_id`，同时保留 `session.id` 与 `gen_ai.conversation.id`。

4. 开启 **Trace 导出**并保存，随后重启控制面并发起一次 AIGateway 请求以验证连通性。

## 配置其他 OTLP/HTTP 接收端

对接通用 OTLP/HTTP 接收端时，请填写目标服务端提供的基础 OTLP 端点地址与认证请求头（端点末尾同样不要包含 `/v1/traces`）。

此类接收端统一选用 `observability.traces.provider=opentelemetry`。在可视化表单中，将下表第三列中的键值对逐行添加为认证请求头即可：

| 接收端 | `observability.traces.otlp_endpoint` | `observability.traces.otlp_headers` |
|---|---|---|
| OpenTelemetry Collector | `http://<collector-host>:4318` | 接收端无需认证时留空（`{}`） |
| VictoriaTraces 单机 | `http://<victoria-traces>:10428/insert/opentelemetry` | 内网直连且无认证代理时留空（`{}`） |
| VictoriaTraces 集群 | `http://<vtinsert>:10481/insert/opentelemetry` | 内网直连且无认证代理时留空（`{}`） |
| Honeycomb US | `https://api.honeycomb.io` | `{"x-honeycomb-team":"<api-key>"}` |
| Honeycomb EU | `https://api.eu1.honeycomb.io` | `{"x-honeycomb-team":"<api-key>"}` |
| Grafana Cloud | 从当前实例的 OpenTelemetry 连接卡片复制基础 `OTEL_EXPORTER_OTLP_ENDPOINT` | `{"Authorization":"Basic <base64(instance-id:access-policy-token)>"}` |

由于 Ankole 会自动在基础端点后追加 `/v1/traces`，发往 VictoriaTraces 的实际请求路径为 `/insert/opentelemetry/v1/traces`。VictoriaTraces 自身不内置租户鉴权；若跨受信网络部署，建议前置 `vmauth` 或其他认证代理，并将代理所需的认证请求头写入 AppConfigure。详见 [VictoriaTraces OTLP 官方文档](https://docs.victoriametrics.com/victoriatraces/data-ingestion/opentelemetry/)。

使用 Honeycomb Classic 时还需额外配置 `x-honeycomb-dataset`；Grafana Cloud 的访问令牌则必须具备 `traces:write` 权限，其基础端点因具体实例而异（通常以 `/otlp` 结尾）。复制账号配置前，请先核对 [Honeycomb OTLP 官方文档](https://docs.honeycomb.io/send-data/opentelemetry)与 [Grafana Cloud OTLP 官方文档](https://grafana.com/docs/grafana-cloud/send-data/otlp/send-data-otlp/)。

选用 `opentelemetry` 模式时，系统不会附加任何 `langfuse.*` 或 `langsmith.*` 专属属性；而选用 `langfuse` 或 `langsmith` 模式也只会为回合根 Span 与 AIGateway LLM Span 补充对应厂商属性，Worker 工具 Span 及控制面的其余 Span 仍保持厂商中立，并一并发往同一接收端。由于 LangSmith 原生兼容标准 OpenTelemetry 客户端上报的通用 Span，启用 `langsmith` 模式时无需丢弃其他 Span。

## 排查导出问题

- **完全看不到 Trace**：确认四项配置均已保存，且控制面已完成重启。
- **收到 Trace 但厂商界面未能识别 LLM 字段**：检查 `observability.traces.provider` 是否与目标平台匹配。
- **接收端报错路径不存在（404）**：检查 AppConfigure 中填写的基础端点末尾是否误加了 `/v1/traces`。
- **Langfuse 返回 `401`**：使用项目的 Public Key 与 Secret Key 重新生成 `Authorization` 值，并确保去除了 Base64 输出中的换行符。
- **Langfuse 已接收数据但迟迟不显示**：检查认证请求头中是否包含值为字符串 `4` 的 `x-langfuse-ingestion-version`。
- **控制面日志出现 `observability.traces.disabled`**：修正无效的端点地址或请求头格式后重启控制面。

请勿通过 `OTEL_TRACES_EXPORTER` 或 `OTEL_EXPORTER_OTLP_*` 环境变量配置 Ankole 的 Trace 导出——在启动 OpenTelemetry 并加载 AppConfigure 中的端点与请求头之前，Ankole 会主动清除这些环境变量，导出器完全由 AppConfigure 统一托管。
