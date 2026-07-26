---
title: 会话历史
description: 如何阅读 agent 说了什么、做了什么——会话列表、每个会话的消息、compaction 如何改变可见记录。
section: User guide
order: 58
---

AIGateway 存储每个会话的转写——消息、模型调用、工具结果——作为持久 PostgreSQL 行。本页是那段历史的运维者视角：如何列出会话、读其消息、理解 compaction 对可见记录做了什么。

先把决定性的性质说清楚：会话转写是 **AIGateway 拥有的持久事实**，compaction 改变模型看到的不删除审计记录。compaction 之前的消息被摘要；摘要是新锚点；原始消息从模型上下文消失，但 compaction 产物保留。

## 列出会话

```bash
curl https://ankole.example.com/api/v1/ai-gateway/conversations \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /ai-gateway/conversations` 列出会话。每个带一个会话 id、它所属的主体（Principal）、元数据。按 agent 或按时间过滤找到你需要的会话。

## 读取消息

```bash
curl https://ankole.example.com/api/v1/ai-gateway/conversations/<conversation_id> \
  -H "Authorization: Bearer $CONSOLE_TOKEN"

curl https://ankole.example.com/api/v1/ai-gateway/conversations/<conversation_id>/messages \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET .../conversations/:id` 读取一个会话的元数据。`GET .../conversations/:id/messages` 读取其消息——assistant 回合、用户消息、工具调用输出，按发生顺序。每条消息带其类型、角色、状态、内容和元数据（含模型响应的模型、provider、token 用量）。

这是"这个回合 agent 实际做了什么？"的界面——调试异常行为时的最快判据。

## compaction 如何改变可见记录

一个跑得长的会话已被压缩（见[上下文压缩与 compaction](../context-compression-and-caching/)）。compaction 后：

- **旧消息被摘要。** 一条 compaction 消息替换旧回合作为会话锚点。模型看到摘要，不是原始回合。
- **近期回合逐字保留。** 最后几个回合（`tail_rows`，默认 2）完整保留。
- **用户原文保留。** 在 token 预算内，被压缩区段的逐字用户消息与摘要一起重放。
- **compaction 产物是持久的。** 产物记录了什么被压缩、何时。它是审计事实，不是被删的消息。

这意味着你通过 Console 读到的消息历史是会话的当前状态——模型现在看到的。若你需要 compaction 前的细节，它已被摘要；摘要是那里曾有之物的记录。

## 消息告诉你什么

每条消息的 `metadata` 字段携带 AIGateway 拥有的事实：

- **模型与 provider**——哪个模型服务了响应，通过哪个 provider。
- **Token 用量**——响应时的累积用量快照。
- **Provider 原始 id**——上游 provider 的响应 id，用于与 provider 自己的日志交叉引用。

这些事实告诉你一次慢或错的响应是模型的锅、provider 的锅、还是配置问题。如何把一条消息追溯回其 provider 见 [Provider 路由](../provider-routing/)。

## 本指南不是什么

它不是 AIGateway 概念页——完整 API 面见 [AIGateway](../ai-gateway/)。它不是 compaction 内部指南——触发、摘要器、保留模型见[上下文压缩与 compaction](../context-compression-and-caching/)。它也不是轨迹格式参考——消息如何存储和投影见[轨迹与消息格式](../trajectory-format/)。

## 下一步

- AIGateway API，读 [AIGateway](../ai-gateway/)。
- compaction，读[上下文压缩与 compaction](../context-compression-and-caching/)。
- 消息存储格式，读[轨迹与消息格式](../trajectory-format/)。
- Console 路由，读 [Console API 参考](../console-api/)。
