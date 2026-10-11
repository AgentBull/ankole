---
title: AIGateway API 使用
description: 外部调用方如何使用 AIGateway REST API——OpenResponses 兼容端点、Agent and OIDC Human tokens、无状态与有状态调用、完整示例。
section: Developer guide
order: 126
---

AIGateway 不只是 worker 调用的内部边界；它是一个外部应用、企业系统和 SDK 可以直接调用的 REST API。本页是调用方使用它的实用指南——端点、鉴权、两种调用模式、完整示例。它以实际调用示例补充 [AIGateway](../ai-gateway/) 概念页。

AIGateway API 兼容 OpenResponses，并按主体隔离数据和权限。调用方出示 Bearer Token（Agent 或 OIDC Human），发送 OpenResponses 格式的请求，再接收 JSON 响应或数据流。Provider 凭证始终由控制面保存，不会暴露给调用方。

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
- **OIDC 人类 token**——由声明 `ai_gateway.write` 的 OIDC Client 为活跃 Human 签发；请求只能使用该 Client 的模型别名，`subject_type = "oidc_human"`。

获取 OIDC 人类 token：在控制台创建带 `ai_gateway.write` 作用域的 OIDC Client，配置允许的组和模型别名，再通过授权码加 PKCE 登录。需要长期使用时申请 `offline_access`，使用轮换的 Refresh Token。Human 必须属于允许的组，且只能使用 Client 的模型别名，不能使用原始 `provider_id/model` 选择符。

Token 怎样解析为主体，见 [主体与 AuthZ](../principal-authz/)。

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
| `GET /models` | 列出当前可用模型 |
| `POST /embeddings` | 生成 embedding |
| `POST /rerank` | 重排文档 |
| `POST /web_search` | 搜索网页 |
| `POST /web_fetch` | 抓取网页 |

各端点在 [AIGateway](../ai-gateway/) 概念页和对应的 User guide 功能页中分别有说明。

## 本指南不是什么

它不是 AIGateway 概念页——完整路由表、有状态生命周期和错误格式见 [AIGateway](../ai-gateway/)。它也不是 SDK——Ankole 不提供客户端 SDK；调用方用标准 HTTP 客户端访问 REST API。

## 下一步

- 完整 AIGateway 面，读 [AIGateway](../ai-gateway/)。
- Provider 的解析和请求准备，读 [Provider Runtime](../provider-runtime/)。
- Console API 参考，读 [Console API 参考](../console-api/)。
