---
title: AIGateway API 使用
description: 外部调用方如何使用 AIGateway REST API——OpenResponses 兼容端点、agent vs admin token、无状态与有状态调用、完整示例。
section: User guide
order: 59
---

AIGateway 不只是 worker 调用的内部边界；它是一个外部应用、企业系统和 SDK 可以直接调用的 REST API。本页是调用方使用它的实用指南——端点、鉴权、两种调用模式、完整示例。它以实际使用补充 [AIGateway](../ai-gateway/) 概念页。

先把决定性的性质说清楚：AIGateway API 是**OpenResponses 兼容且按 Principal 范围限定的**。调用方出示 bearer token（agent 或 admin），发送 OpenResponses 形态的请求，收到 JSON 响应或流。调用方永远看不到 provider 凭证——控制面拥有它们。

## 鉴权

`/api/v1/ai-gateway` 下的每次调用需要 bearer token：

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "你好" }'
```

接受两种 token：

- **Agent token**——范围限定到一个 agent 的模型绑定。集成代表特定 agent 行动时用它。
- **Admin token**——范围限定到所有 provider。运维侧脚本和 Console 用它。

token 如何解析为 Principal 见 [Principal 与 AuthZ](../principal-authz/)。

## 无状态响应（HTTP 和 SSE）

无状态调用是一次请求、一次响应。发送完整输入；拿回完整响应体：

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "总结这个 thread。", "store": false }'
```

流式加 `"stream": true`，同一端点切到 Server-Sent Events：

```bash
curl -N https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "起草一份发布说明。", "stream": true }'
```

无状态 HTTP 和 SSE 拒绝有状态字段（`previous_response_id`、`conversation`、`store`）。续接用 WebSocket 路径。

## 其它端点

| 端点 | 用途 |
|---|---|
| `GET /models` | 列出可用模型（见[模型目录](../model-catalog/)） |
| `POST /embeddings` | 生成 embedding |
| `POST /rerank` | 重排文档 |
| `POST /web_search` | 搜索网页 |
| `POST /web_fetch` | 抓取网页 |
| `GET /web_tools` | 列出可用 web 工具 |

各自在 [AIGateway](../ai-gateway/) 概念页和相关的 User-guide 功能页中文档化。

## 本指南不是什么

它不是 AIGateway 概念页——完整路由表、有状态生命周期、错误信封见 [AIGateway](../ai-gateway/)。它不是 provider 配置指南——绑定模型见 [Provider 与模型](../providers-and-models/)。它也不是 SDK——Ankole 不提供客户端 SDK；调用方用标准 HTTP 客户端访问 REST API。

## 下一步

- 完整 AIGateway 面，读 [AIGateway](../ai-gateway/)。
- 模型目录，读[模型目录](../model-catalog/)。
- provider 路由，读 [Provider 路由](../provider-routing/)。
- Console API 参考，读 [Console API 参考](../console-api/)。
