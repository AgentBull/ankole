---
title: Codex 账户
description: 如何为 CodexRunner 后台任务管理 ChatGPT 订阅账户——创建、配置、轮换任务运行所用的账户。
section: User guide
order: 41
---

一个 Codex 账户是后台 Agent 任务运行所在的持久 ChatGPT 订阅账户。默认账户是 `aigateway`，经 AIGateway 的 provider 绑定路由。当任务需要直接 CodexRunner 访问——不同的订阅层、特定模型、限速隔离——你创建并配置额外账户。本页是该管理面的运维者视角。

先把决定性的性质说清楚：Codex 账户是**持久配置，不是你敲进任务的凭证**。账户住在 PostgreSQL 里、静态加密，任务通过 `codex_account_id` 引用它。worker 在回合时通过一个带隔离栏的 RPC 解析账户凭证——它从不以环境变量收到原始凭证。

## 默认账户

每个任务带一个 `codex_account_id`，默认是 `aigateway`。此账户经 AIGateway 的 provider 绑定路由——与 agent 的 model profile 解析到的 provider 相同。多数部署默认就够了：任务跑在与会话回合相同的 provider 链上。

你不需要创建或配置 `aigateway` 账户；它是内置默认。只在任务需要默认不提供的东西时创建额外账户。

## 何时创建单独账户

- **限速隔离**——长时运行的研究任务不应与会话回合争同一限速池。单独账户给它自己的池。
- **不同订阅层**——任务需要默认账户订阅不覆盖的模型或 reasoning effort。
- **计费分离**——在单独账户上跟踪特定工作负载的用量。

以上都不适用时，默认账户是对的。

## 创建和管理账户

通过 Console 的 `/codex-accounts` 路由：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/codex-accounts` | 列出账户 |
| `POST` | `/codex-accounts` | 创建账户 |
| `PUT` | `/codex-accounts/:account_id` | 更新账户 |
| `DELETE` | `/codex-accounts/:account_id` | 移除账户 |

创建账户时，订阅凭证静态加密存储。账户的 auth 在任务运行时通过 `CodexAccountBroker` 解析，它是回合隔离的——worker 收到的是有时限的解析后凭证，不是存储的 secret。

## 给任务分配账户

任务的 `codex_account_id` 字段选择账户。默认是 `aigateway`；设不同 id 把任务路由到特定账户。此字段在 job schema 上，任务创建时（由 agent）设定，可通过 Console 的 `/background-agent-jobs/:id` 路由看到。

agent 不从菜单选账户——`codex_account_id` 是默认或由配置设定。运维者的工作是创建账户；任务通过其配置拿到对的那个。

## 轮换凭证

订阅凭证变更时（密码轮换、token 刷新），通过 `PUT /codex-accounts/:account_id` 更新账户。旧凭证被覆盖；在此账户上运行的任务在下次回合捡起新凭证。不要为"检查"而解密旧凭证——设新值，让 broker 解析它。

## 本指南不是什么

它不是 ChatGPT 订阅教程——订阅本身是 OpenAI 的产品，账户字段是其 API 的事。它不是任务创建指南——任务运维视角见[后台任务（运维视角）](../background-jobs-ops/)。它也不是 Console API 参考的替代；确切的请求形态在那里。

## 下一步

- 任务面，读[后台任务（运维视角）](../background-jobs-ops/)。
- CodexRunner（使用这些账户的引擎），读 [Codex 集成](../codex-integration/)。
- Console 路由，读 [Console API 参考](../console-api/)。
