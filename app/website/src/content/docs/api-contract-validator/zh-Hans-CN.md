---
title: API 契约验证器
description: 如何设置一个把 API 实现与 OpenAPI spec 对照验证的 agent——检查形态、类型、状态码、报告漂移。
section: Guides
order: 356
---

一个 API 契约验证器 agent 读 OpenAPI 规格、向实际 API 发请求、检查实现是否匹配文档化的契约——响应形态、字段类型、状态码、错误格式。这是 [API 测试 agent](../api-testing-agent/) 的特化版，聚焦契约漂移而非功能正确性。本指南是那个 agent 的实际形态。

先把决定性的性质说清楚：agent **验证契约不验证行为**。它检查 API 响应是否匹配 spec 承诺的——不检查行为是否正确。一个响应可以契约合法但行为错误（spec 说"返回 user 对象"确实返回了，但 user 对象的数据错了）。agent 抓形态漂移；人抓语义 bug。

## 需要什么

- **绑定 `primary` 和 `coding` profile**——读 OpenAPI spec 并把它与响应比较需要结构化推理。
- **一个 signal binding** 到验证报告发帖的频道。
- **API 从 worker 可达**——staging URL 或本地服务器。
- **OpenAPI spec**——repo 里的文件、通过 `web_fetch` 抓取、或服务在 `/openapi.json`。

## 工作流

1. **验证任务到达**——定时或 spec 变更后。
2. **agent 读 OpenAPI spec**——解析路径、方法、请求 schema、响应 schema、状态码。
3. **agent 发请求**——对 spec 里的每个 path+method 发一个请求（带有效 auth 和代表性 body）。
4. **agent 比较**——检查实际响应与 spec：状态码匹配、响应体有文档化的字段和类型、错误响匹配文档化的错误 schema。
5. **agent 报告漂移**——spec 与实现之间的任何不匹配。

## 漂移报告

```text
**契约验证 — <日期>**
**检查的端点**：42
**通过**：38
**漂移**（spec 说 X，实现做 Y）：
- `GET /users/:id`：spec 说 `200` 返回 `{id, name, email}`；实现返回 `{id, name, email, created_at}`。多余字段。
- `POST /orders`：spec 说 `400` 返回 `{error: {code, message}}`；实现返回 `{error: string}`。形态不匹配。
- `DELETE /sessions/:id`：spec 说 `204`；实现返回 `200`。状态不匹配。
```

三类漂移——多余字段、形态不匹配、状态不匹配——是最常见的契约漂移模式。agent 每个报告端点、spec 声明、实现实际行为。

## 人设控制什么

- **范围**——"验证 spec 里的所有路径"vs"只验证自上次 spec commit 以来修改的路径"。
- **严格度**——"多余字段标记为漂移"vs"允许多余字段（前向兼容添加）"。
- **Auth**——"对需鉴权的端点用 WorkerEnv 里的 staging API key。"
- **报告**——"每个漂移作为单独发现报告，附 spec 引用和实际响应。"

## 一个完整示例

为 REST API 设置契约验证器：

1. 绑 `primary`/`coding` + 把 staging API key 存 WorkerEnv。
2. 撰写 `MISSION.md`："从 `openapi.json` 读 OpenAPI spec。对每个 path+method 向 staging API 发请求。把响应与 spec 比较：状态码、响应体形态、字段类型。报告漂移：多余字段、缺失字段、类型不匹配、状态不匹配。仅在 `metadata` 对象里的多余字段允许。发报告。"
3. 加一条每次部署后运行的调度：`cron: "0 * * * *"`（每小时），或从 webhook 触发。
4. agent 读 spec、发请求、比较、发漂移报告。

## 本指南不是什么

它不是功能测试——它检查形态不检查数据正确性。它不是 spec 生成器——它针对已有 spec 验证；它不写 spec（那个见[代码文档 agent](../code-documentation-agent/)）。它也不是跨版本破坏性变更检测器——它检查当前实现与当前 spec；比较两个 spec 版本是不同任务。

## 下一步

- API 测试模式（功能而非契约），读 [API 测试 agent](../api-testing-agent/)。
- 代码文档模式（从代码生成文档），读[代码文档 agent](../code-documentation-agent/)。
- shell 工具（发请求），读[代码执行](../code-execution/)。
- 调度，读 [Cron 调度](../cron-schedules-ops/)。
