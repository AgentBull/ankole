---
title: Agent
description: 如何创建和管理一个 agent——它的身份、人设文档、model profile、能力，以及把它接到共享工作上的 binding。
section: User guide
order: 13
---

agent 是 Ankole 里其它一切配置所围绕的单位。provider 绑定、model profile、signal binding、library 能力、后台任务，全都挂在某一个 agent 上。本页是运维者走过一个 agent 生命周期的路径：创建它、给它人设、接上模型、启用能力、连接到共享工作。

先把决定性的性质说清楚：一个 agent 是一个持久的 Principal，带一个稳定的 `uid`。你为它配置的一切——profile、文档、binding——都指向那个 uid，所以改显示名永远不会弄断 binding。

## 创建一个 agent

```bash
curl -X POST https://ankole.example.com/api/v1/agents \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "display_name": "发布说明机器人" }'
```

响应带着 agent 的 `uid`，你之后的每条路由都用它。用 `GET /agents` 列出 agent，用 `GET /agents/:agent_uid` 读取一个，用 `PATCH /agents/:agent_uid` 更新它的展示字段，用 `DELETE /agents/:agent_uid` 移除一个。移除是破坏性的——它的 binding、profile 和 library 状态会一起走——所以如果只是想让它安静，先禁用它的 signal binding。

## 给它人设

一个 agent 每个回合会读三份运行时文档，你通过 library-documents 界面撰写它们：

| 文档 | 用途 |
|---|---|
| `mission`（`MISSION.md`） | agent 为何存在，它的范围与职责 |
| `soul`（`SOUL.md`） | agent 如何说话和行事——语气、风格、边界 |
| `design`（`DESIGN.md`） | agent 必须遵守的工作约定与约束 |

设定一份：

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/library-documents/mission \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "content": "你是发布说明机器人。你关注合并的 PR……" }'
```

这些是 agent 自己的可写文件——它们住在它的 `/agents/<key>/` 工作空间里，由 Agent Computer 每个回合读取。用 `GET /agents/:agent_uid/library-documents` 列出它们。用平实的散文写；agent 把它们当作权威上下文，而不是盲目服从的指令。

## 接上它的模型

一个 agent 没有模型就跑不起来。至少绑三个必需的 profile 槽——`primary`、`light`、`heavy`——以及 agent 需要的可选槽（`embedding`、`web_search`、`coding` 等）。完整的槽列表和 provider 配置那一步，见 [Provider 与模型](../providers-and-models/)。

## 启用它的能力

agent 的能力——它能用哪些 Agent Plugin 和 skill——来自 Agent Library。模型是“默认再覆盖”：能力有部署范围的默认值，你按 agent 收窄或放宽。

- 看 agent 的有效能力：`GET /agents/:agent_uid/library-capabilities`。
- 为某一个 agent 覆盖一个 plugin：`PUT /agents/:agent_uid/library-capabilities/agent-plugins/:id`。
- 为某一个 agent 覆盖一个 skill：`PUT /agents/:agent_uid/library-capabilities/skills/:id`。
- 不 fork 就为这个 agent 定制某个 skill 的行为：`PUT /agents/:agent_uid/library-skill-overlays/:skill_name`。

默认再覆盖的模型，以及“已启用”在回合时刻意味着什么，读 [Agent Library](../agent-library/) 开发者页。

## 把它接到共享工作

一个有模型和能力、却没有 signal binding 的 agent，是一个谁都够不到的 agent。一个 signal binding 把一个 provider adapter——Lark、钉钉、Slack、Microsoft 365、Google Workspace——绑到 agent 上，让消息、webhook 和事件变成它会被唤醒的 actor 事件。见 [Signal binding](../signal-bindings/) 和用户指南下各 adapter 的专页。

## 观察 agent 运行

agent 接好并开始收信号之后，Console 显示它在做什么：

- **session**——`GET /agents/:agent_uid/sessions` 列出该 agent 的长时 session，每一个是一个以 `{agent_uid, session_id}` 为键的 actor。
- **按 session 的调度**——`/agents/:agent_uid/sessions/:session_id/cron-schedules` 和 `.../checkbacks` 显示一个 session 上已调度和已推迟的工作。
- **后台任务**——`/background-agent-jobs` 显示该 agent 派生的持久任务；按 agent 过滤就只看它自己的。
- **会话**——`/ai-gateway/conversations` 显示近期回合做过的模型调用，这是看 agent 是否解析到了你配置的模型的最快途径。

## 关于 agent Principal

一个 agent 是一个 Principal——和人类管理员一样的可问责主体形态。它的权限像任何 Principal 一样通过 AuthZ 授予和求值，禁用 agent Principal 会跨部署移除它的权限。运维界面是 `/principals`；模型在 [Principal 与 AuthZ](../principal-authz/) 开发者页。

## 下一步

- model profile 绑定，读 [Provider 与模型](../providers-and-models/)。
- 把 agent 接到聊天平台，读 [Signal binding](../signal-bindings/) 和各 adapter 专页。
- 路由，读 [Console API 参考](../console-api/)。
