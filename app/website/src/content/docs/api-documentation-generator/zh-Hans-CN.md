---
title: API 文档生成器
description: 如何设置一个从代码生成 API 文档的 agent——端点参考页、请求/响应示例、错误目录——从路由定义和类型。
section: Guides
order: 364
---

一个 API 文档生成器 agent 读代码库的路由定义、请求/响应类型、和错误处理器，生成结构化 API 文档——带参数、响应形态、状态码、和示例的端点参考页。本指南是那个 agent 的实际形态。它是[代码文档 agent](../code-documentation-agent/) 聚焦 API 面的变体。

先把决定性的性质说清楚：agent **从代码而非 spec 文档化 API**。它读路由实际接受和返回什么，写匹配实现的文档。若实现和 spec 不一致，agent 文档化实现（并标记漂移）。价值在于保持 API 文档与代码同步。

## 需要什么

- **WorkerEnv 里的 git 凭证**（`GIT_TOKEN`）。见 [Git 集成](../git-integration/)。
- **绑定 `primary` 和 `coding` profile**——读路由定义和类型需要代码理解能力。
- **一个 signal binding** 到文档草稿发帖的频道。
- **repo 从 worker 可达**，带 agent 能发现的路由定义。

## 工作流

1. **文档任务到达**——定时或 API 变更后。
2. **agent 发现路由**——读路由文件找每个端点：方法、路径、handler、middleware。
3. **agent 读每个 handler**——每个路由：参数（path、query、body）、响应类型、状态码、错误情况。
4. **agent 读类型**——请求 body schema、响应 body schema、错误信封。
5. **agent 生成文档**——每个端点一页参考（或每个资源组一页），带方法、路径、参数、响应、错误、和 curl 示例。
6. **agent 发草稿**——或开带文档变更的 PR。

## 端点参考

agent 生成的一个好的 API 参考页：

```markdown
## POST /api/v1/payments

创建一笔支付。

**请求 body**：
| 字段 | 类型 | 必需 | 描述 |
|---|---|---|---|
| amount | number | 是 | 支付金额，以分为单位 |
| currency | string | 是 | ISO 4217 货币代码 |
| customer_id | string | 是 | 要收费的客户 |

**响应**：
| 状态 | Body | 描述 |
|---|---|---|
| 200 | `Payment` | 创建的支付 |
| 400 | `Error` | 请求 body 无效 |
| 402 | `Error` | 支付被 provider 拒绝 |
| 500 | `Error` | 内部服务器错误 |

**示例**：
```bash
curl -X POST https://api.example.com/v1/payments \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"amount": 5000, "currency": "usd", "customer_id": "cus_123"}'
```
```

## 人设控制什么

- **发现**——"读 Elixir 的 Phoenix 路由（`lib/.../router.ex`）、Node 的 Express 路由、或框架的路由声明。"
- **深度**——"带 curl 示例的完整参考"vs"带方法、路径、和一行描述的摘要表"。
- **分组**——"每个资源组一页（payments、users、auth）"vs"每个端点一页"。
- **漂移检测**——"若 OpenAPI spec 存在，把生成的文档与它比较。标记任何不匹配。"

## 一个完整示例

为 Phoenix API 设置 API 文档生成器：

1. 在 WorkerEnv 存 `GIT_TOKEN`。
2. 创建 agent，绑 `primary`/`coding`。
3. 撰写 `MISSION.md`："读 `lib/ankole_web/router.ex` 里的路由。对 `/api/v1` 下的每个路由，读 controller 和 schema 模块。为每个资源组生成 Markdown 参考页，含：方法、路径、参数、响应类型、状态码、和 curl 示例。发草稿请求复核。不改代码。"
4. 在频道里："生成 payments 和 auth 端点的 API 文档。"
5. agent 读路由、读 controller 和 schema、生成参考页、发草稿。

## 本指南不是什么

它不是 OpenAPI spec 生成器——它生成人可读文档，不是机器可读 spec（尽管它可以读已有 spec 做漂移检测）。spec 验证见 [API 契约验证器](../api-contract-validator/)。它不是代码文档 agent——它文档化 API 面不文档化内部代码。它也不是人类技术作者的替代——生成的文档是草稿；作者加上下文、用例、和叙事。

## 下一步

- 代码文档模式（内部文档而非 API），读[代码文档 agent](../code-documentation-agent/)。
- 契约验证器（spec 与实现漂移），读 [API 契约验证器](../api-contract-validator/)。
- git 设置，读 [Git 集成](../git-integration/)。
- shell 工具，读[代码执行](../code-execution/)。
