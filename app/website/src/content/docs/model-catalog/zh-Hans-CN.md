---
title: 模型目录
description: 如何使用 GET /models 端点——OpenRouter 风格目录、过滤器、agent 或 API 调用方看到什么。
section: User guide
order: 54
---

模型目录是调用方问"我能用哪些模型"时看到的东西。AIGateway 通过 `GET /ai-gateway/models` 以 OpenRouter 风格形态服务它，外部 API 客户端和 Console 都消费它。本页是该端点的运维者视角——返回什么、如何过滤、agent 主体和 admin 主体之间有何不同。

先把决定性的性质说清楚：目录是**按主体范围限定的**。agent 看到其 profile 解析到的模型；admin 看到每个 provider 的模型。同一端点按谁在问返回不同列表——因为你能调用什么由你的 AuthZ 授予隔离，不是由全局模型列表。

## 端点

```bash
curl https://ankole.example.com/api/v1/ai-gateway/models \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN"
```

`GET /ai-gateway/models` 返回模型目录。响应是 OpenRouter 风格——一个模型对象列表，每个带 id、名称、定价、上下文窗口、支持的能力。

## 过滤器

端点接受查询参数收窄目录：

| 参数 | 用途 |
|---|---|
| `q` | 模型名自由文本搜索 |
| `context` | 最小上下文长度 |
| `min_price` / `max_price` | 价格范围 |
| `sort` | OpenRouter 风格排序键 |
| `output_modalities` | 逗号分隔的输出模态过滤 |
| `input_modalities` | 逗号分隔的输入模态过滤 |
| `supported_parameters` | 逗号分隔的请求参数过滤 |

这些与 OpenRouter 目录接受的过滤器相同。一个寻找"至少 128k 上下文、支持工具调用的便宜模型"的 API 客户端可以编程过滤，而非扫描整个列表。

## agent 看到 vs admin 看到

目录按主体解析：

- **agent token** 看到其 provider 绑定暴露的模型——其 profile 解析到的选择符，加上 provider 的完整模型列表供显式 `provider_id/model` 选择。
- **admin token** 看到每个 provider 的模型——跨所有已配置 provider 的完整目录。

这与其他每个 AIGateway 端点的 AuthZ 范围模型相同。目录不是全局列表；它是调用方被授权调用的东西。

## 如何使用

- **作为 API 调用方**——查目录找到一个符合需求的模型（上下文、价格、能力），然后把其 id 作为 `/responses` 请求的 `model` 字段发送。
- **作为运维者**——用它验证配置后 provider 的模型可见。刚加的 provider 不在目录里，说明绑定不完整或 provider 被禁用。
- **作为 agent 的系统 prompt**——目录不注入 prompt。agent 看到其 model profile（primary、light、heavy），不是目录。目录面向 API 调用方和运维者。

## 本指南不是什么

它不是模型比较站点——目录的定价和能力数据来自 provider，Ankole 不策展它。它不是 provider 配置指南——如何绑定 profile 见 [Provider 与模型](../providers-and-models/)。它也不是 AIGateway 概念页——完整 API 面见 [AIGateway](../ai-gateway/)。

## 下一步

- 绑定 model profile，读 [Provider 与模型](../providers-and-models/)。
- AIGateway API 面，读 [AIGateway](../ai-gateway/)。
- provider 路由，读 [Provider 路由](../provider-routing/)。
- Console 路由，读 [Console API 参考](../console-api/)。
