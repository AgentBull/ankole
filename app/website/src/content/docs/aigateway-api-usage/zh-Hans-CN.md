---
title: AIGateway API 使用
description: 面向外部调用方的 AIGateway REST API 实用指南：兼容 OpenResponses 的端点、Agent 与 OIDC 人类令牌鉴权、无状态与流式调用示例。
section: Developer guide
order: 126
---

AIGateway 不仅是内部 Worker 调用的模型边界，也是一套可直接供外部应用、企业业务系统和各类 SDK 调用的 REST API。本页作为 [AIGateway](../ai-gateway/) 架构文档的实战补充，通过完整请求示例说明外部调用方如何完成鉴权、选择调用模式并访问常用端点。

AIGateway API 遵循 OpenResponses 规范，并按调用主体严格隔离数据与权限。调用方只需在请求中出示 Bearer Token（Agent 令牌或 OIDC 人类令牌），发送 OpenResponses 格式的请求，即可接收 JSON 响应或事件流；上游 Provider 的密钥凭证始终保存在控制面内，不会暴露给调用方。

## 鉴权

访问 `/api/v1/ai-gateway` 下的任意端点都必须在请求头中携带 Bearer Token：

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "你好" }'
```

网关接受以下两类令牌：

- **Agent Token**：权限范围限定在单个 Agent 的模型绑定内，适用于外部集成代表特定 Agent 发起调用的场景。
- **OIDC 人类令牌**：由声明了 `ai_gateway.write` 作用域的 OIDC 客户端为活跃人类用户（Human）签发；请求只能使用该客户端配置的模型别名，`subject_type = "oidc_human"`。

获取 OIDC 人类令牌的方法：先在控制台中创建带有 `ai_gateway.write` 作用域的 OIDC 客户端，配置允许访问的权限组与模型别名，再通过授权码加 PKCE 流程登录；需要长期调用时可申请 `offline_access`，配合轮换式 Refresh Token 使用。人类用户必须属于客户端允许的权限组，且只能传入客户端公开的模型别名，不能使用原始的 `provider_id/model` 选择符。

关于令牌如何解析为系统主体，请参阅 [主体与 AuthZ](../principal-authz/)。

## 无状态响应（HTTP 和 SSE）

无状态调用采用“一次请求、一次响应”模式。提交完整输入后，接口直接返回完整的 JSON 响应体：

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "总结这段对话。", "store": false }'
```

如需流式接收生成内容，在请求体中加入 `"stream": true"`，同一端点即切换为 Server-Sent Events（SSE）流：

```bash
curl -N https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "起草一份发布说明。", "stream": true }'
```

无状态 HTTP 与 SSE 请求均拒绝有状态字段（`previous_response_id`、`conversation`、`store`）；如需跨回合持久化续接对话，请改走 WebSocket 端点。

## 其它端点

| 端点 | 用途 |
|---|---|
| `GET /models` | 列出当前主体可用的模型 |
| `POST /embeddings` | 生成向量嵌入（Embedding） |
| `POST /rerank` | 对文档列表重排序 |
| `POST /web_search` | 搜索公开网页 |
| `POST /web_fetch` | 抓取网页正文 |

各端点的详细参数说明请参阅 [AIGateway](../ai-gateway/) 及用户指南中的对应功能页。

## 本指南不是什么

本页不是完整的网关协议规范——全量路由表、WebSocket 有状态生命周期与错误码定义请查阅 [AIGateway](../ai-gateway/)。同时，Ankole 也不单独维护专用客户端 SDK，调用方使用任意标准 HTTP 客户端或兼容 OpenResponses 的通用客户端即可直接接入。

## 下一步

- 查阅完整的 AIGateway 路由契约与有状态连接规范，请参阅 [AIGateway](../ai-gateway/)。
- 了解底层 Provider 的路由解析与请求组装机制，请参阅 [Provider Runtime](../provider-runtime/)。
- 查阅管理控制台的接口规范，请参阅 [Console API 参考](../console-api/)。
