---
title: LLM 可观测性
description: 把带有 AIGateway LLM 语义的可选跨运行时 Agent Turn trace 导出到 OTLP/HTTP 接收端。
section: User guide
order: 44
---

Ankole 可以通过 OpenTelemetry Protocol（OTLP）HTTP/protobuf 导出 OpenTelemetry trace。此功能默认关闭。`observability.traces.provider` 选择添加到 Turn 根与 AIGateway LLM span 的 vendor 属性，不是 AIGateway 模型 Provider，不实现传输，也不筛选其他 OpenTelemetry span。所有 provider 共用进程级 OpenTelemetry SDK 和 OTLP exporter：

- `langfuse` 增加 Langfuse v4 agent 与 generation 属性。
- `langsmith` 增加 LangSmith run type 和兼容内容属性。
- `opentelemetry` 只发送通用 OpenTelemetry、`gen_ai.*` 和 Ankole 属性，适用于 VictoriaTraces、Honeycomb、Grafana Cloud 和 Collector。

启用后，trace 包含模型输入和输出，也可能包含工具参数和结果。Ankole 会删除已配置的凭证、请求头、通用调用方 metadata、加密的推理和工具字段，以及内部 `__ankole_*` 字段。Ankole 会把内联 `data:` 媒体替换为字节数，并忽略超过 1 MiB 的输入或输出载荷。接收端仍必须是受信系统，并配置合适的访问控制和保留策略。

每个已派发的 Agent Turn 对应一条 trace。`turn <事件类型>` 根 span 在 Langfuse 中是 agent observation，并包含经过清理的触发事件与最终回复。主 Agent 的工具 span 和 AIGateway 响应 span 都挂在该根下；后台 Job 还包含 `codex.turn` 与 Codex 工具 span。没有 Turn 上下文的 AIGateway 直接调用仍以 `ai_gateway.response` 为根。Agent Computer 通过已认证的 Runtime Fabric RPC lane 上交 protobuf OTLP 批次，因此接收端凭证只留在控制面。

## 配置 Langfuse

以下步骤与 [Langfuse 原生 OpenTelemetry 指南](https://langfuse.com/integrations/native/opentelemetry)和 [Langfuse v4 迁移检查表](https://langfuse.com/integrations/native/opentelemetry/migration-to-v4)一致。

### 前置条件

- 创建 Langfuse 项目。从 **Settings → API Keys** 复制项目 Public Key（`pk-lf-...`）和 Secret Key（`sk-lf-...`）。
- 按项目所在区域选择 endpoint：

| 部署 | `observability.traces.otlp_endpoint` |
|---|---|
| Langfuse Cloud EU | `https://cloud.langfuse.com/api/public/otel` |
| Langfuse Cloud US | `https://us.cloud.langfuse.com/api/public/otel` |
| Langfuse Cloud Japan | `https://jp.cloud.langfuse.com/api/public/otel` |
| Langfuse Cloud HIPAA | `https://hipaa.cloud.langfuse.com/api/public/otel` |
| 自托管 Langfuse 3.22.0 或更高版本 | `https://<langfuse-host>/api/public/otel` |

endpoint 必须是基础地址，不要包含 `/v1/traces`。Ankole 会追加 `/v1/traces`，并发送 `application/x-protobuf`。Langfuse 的此 endpoint 不接受 OTLP/gRPC。

### 生成 Authorization 值

Basic Auth 以项目 Public Key 作为用户名，以项目 Secret Key 作为密码。运行以下命令，生成不带换行符的 Base64 值：

```bash
printf '%s' 'pk-lf-...:sk-lf-...' | base64 | tr -d '\n'
```

配置请求头时，在结果前添加 `Basic `。不要把两个独立的 Langfuse Key 写入 AppConfigure。

### 写入 AppConfigure

打开 **Console → 系统配置 → LLM 可观测性**，按以下顺序填写可视化表单：

1. Trace Provider 选择 **Langfuse**。
2. 填写所选基础 endpoint。
3. 添加以下认证请求头行，并替换 `<base64-value>`：

   | 请求头名称 | 请求头值 |
   |---|---|
   | `Authorization` | `Basic <base64-value>` |
   | `x-langfuse-ingestion-version` | `4` |

4. 打开 **Trace 导出**并保存。
5. 重启控制面。这四个值只在控制面启动时读取一次。
6. 发送一条普通 Agent 消息或运行一个后台 Job，然后打开 Langfuse 项目。页面应显示一个 `turn <事件类型>` agent 根 observation。主 Agent trace 包含 `tool <名称>` 与 `ai_gateway.response` 子 span，每个响应下包含 `chat <model>` generation；后台 Job 还包含 `codex.turn` 与 Codex 工具 span。AIGateway 直接调用仍显示为 `ai_gateway.response` 根。provider 原生 compaction 调用会显示为独立的 `compact <model>` generation。

`x-langfuse-ingestion-version: 4` 会选择 Langfuse v4 实时摄取路径。缺少此请求头时，直接摄取的数据可能延迟显示。headers 值会加密保存到 PostgreSQL，保存后在 Console 中显示为掩码。

Langfuse 的分组无需额外配置。Agent Principal 就是 Langfuse user；会话——主 Agent 对话或后台 Job 的 Codex 会话——就是 Langfuse session。trace metadata 以可筛选键携带 Principal 类型、内部调用方与客户端 originator。在控制面设置可选的 `ANKOLE_ENV` 与 `ANKOLE_VERSION` 进程环境变量，可为每条 trace 标注 Langfuse environment（小写字母、数字、`-` 与 `_`，最长 40 字符）与 release。

如需关闭导出，把 `observability.traces.enabled` 设为 `false`，然后重启控制面。导出失败不会改变 Turn 或 AIGateway 模型请求的结果，但 trace 是尽力传输，Ankole 不为它维护投递 outbox。

## 配置 LangSmith

以下配置与 [LangSmith OpenTelemetry 官方文档](https://docs.langchain.com/langsmith/trace-with-opentelemetry)和 [LangSmith OpenTelemetry 发布说明](https://www.langchain.com/blog/opentelemetry-langsmith)一致。Ankole 会发送 LangSmith 当前映射的 `langsmith.span.kind`、`gen_ai.prompt`、`gen_ai.completion`、模型和 token 用量属性。

1. 打开 **Console → 系统配置 → LLM 可观测性**，Trace Provider 选择 **LangSmith**。
2. 按 LangSmith 区域设置基础 endpoint。不要追加 `/v1/traces`：

   | 部署 | `observability.traces.otlp_endpoint` |
   |---|---|
   | GCP US | `https://api.smith.langchain.com/otel` |
   | GCP EU | `https://eu.api.smith.langchain.com/otel` |
   | GCP APAC | `https://apac.api.smith.langchain.com/otel` |
   | AWS US | `https://aws.api.smith.langchain.com/otel` |
   | 自托管 | `https://<langsmith-api-host>/api/v1/otel` |

3. 添加以下认证请求头行：

   | 请求头名称 | 请求头值 |
   |---|---|
   | `x-api-key` | `<langsmith-api-key>` |
   | `Langsmith-Project` | `<project-name>` |

   `Langsmith-Project` 可以省略；省略后 trace 进入 `default` Project。AIGateway Response 属于某个 conversation 时，`langsmith` provider 会把 conversation ID 写入 LangSmith 官方定义的 `langsmith.trace.session_id`，并同时保留 `session.id` 和 `gen_ai.conversation.id`。

4. 打开 **Trace 导出**并保存，然后重启控制面并发起一次 AIGateway 请求。

## 配置其他 OTLP/HTTP 接收端

使用接收端提供的基础 OTLP endpoint 和认证请求头。endpoint 不要包含 `/v1/traces`。

这些接收端都使用 `observability.traces.provider=opentelemetry`。
在可视化表单中，把下表 headers 列中的每一项分别添加为一行认证请求头。

| 接收端 | `observability.traces.otlp_endpoint` | `observability.traces.otlp_headers` |
|---|---|---|
| OpenTelemetry Collector | `http://<collector-host>:4318` | 接收端不要求认证时使用 `{}` |
| VictoriaTraces 单机 | `http://<victoria-traces>:10428/insert/opentelemetry` | 内网且没有认证代理时使用 `{}` |
| VictoriaTraces 集群 | `http://<vtinsert>:10481/insert/opentelemetry` | 内网且没有认证代理时使用 `{}` |
| Honeycomb US | `https://api.honeycomb.io` | `{"x-honeycomb-team":"<api-key>"}` |
| Honeycomb EU | `https://api.eu1.honeycomb.io` | `{"x-honeycomb-team":"<api-key>"}` |
| Grafana Cloud | 从当前 stack 的 OpenTelemetry connection tile 复制基础 `OTEL_EXPORTER_OTLP_ENDPOINT` | `{"Authorization":"Basic <base64(instance-id:access-policy-token)>"}` |

Ankole 会给上述基础 endpoint 追加 `/v1/traces`，所以 VictoriaTraces 的最终请求路径是 `/insert/opentelemetry/v1/traces`。VictoriaTraces 本身不提供租户鉴权；跨受信网络部署时，应使用 vmauth 或其他认证代理，并把代理要求的 headers 写入 AppConfigure。参阅 [VictoriaTraces OTLP 官方文档](https://docs.victoriametrics.com/victoriatraces/data-ingestion/opentelemetry/)。

Honeycomb Classic 还要求 `x-honeycomb-dataset`。Grafana Cloud token 必须包含 `traces:write`；endpoint 由具体实例决定，通常以 `/otlp` 结尾。复制当前账号配置前，查阅 [Honeycomb OTLP 官方文档](https://docs.honeycomb.io/send-data/opentelemetry)和 [Grafana Cloud OTLP 官方文档](https://grafana.com/docs/grafana-cloud/send-data/otlp/send-data-otlp/)。

`opentelemetry` provider 不增加 `langfuse.*` 或 `langsmith.*` 属性。选择 `langfuse` 或 `langsmith` 只会丰富 Turn 根与 AIGateway LLM span；Worker 工具 span 和控制面的其他 span 保持 vendor-neutral，并发往同一个已配置接收端。LangSmith 接受标准 OpenTelemetry client 发送的 span，因此选择 `langsmith` 不要求 Ankole 丢弃无关 span。

## 排查导出问题

- 没有 trace 时，确认四个配置都已保存，并且控制面已经重启。
- trace 有数据但 vendor 页面没有正确识别 LLM 字段时，确认 `observability.traces.provider` 与目标 vendor 一致。
- 接收端报告路径不存在时，确认 AppConfigure 中保存的是基础 OTLP endpoint，末尾没有 `/v1/traces`。
- Langfuse 返回 `401` 时，重新使用项目 Public Key 和 Secret Key 生成 `Authorization`，并删除 Base64 输出中的换行符。
- Langfuse 已接收 trace 但没有及时显示时，确认 headers 包含字符串值为 `4` 的 `x-langfuse-ingestion-version`。
- 控制面日志出现 `observability.traces.disabled` 时，修正 endpoint 或 headers，然后重启控制面。

不要用 `OTEL_TRACES_EXPORTER` 或 `OTEL_EXPORTER_OTLP_*` 配置 Ankole。Ankole 会在 OpenTelemetry 启动前，以及应用 AppConfigure endpoint 和 headers 前删除这些变量。这个 exporter 只由 AppConfigure 管理。
