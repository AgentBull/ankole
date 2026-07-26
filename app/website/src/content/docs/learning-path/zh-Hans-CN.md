---
title: 学习路径
description: 按你想做的事选一条穿过 Ankole 文档的路径——安装并运行、配置 agent、运维部署，或理解内部机制。
section: Getting started
order: 0
---

Ankole 能做很多事——托管共享 AI 同事、接聊天平台、跑长时后台工作、持有持久记忆。本页帮你按目标，而不是按你已知多少，决定从哪里开始。

如果还没安装 Ankole，从[介绍](../introduction/)开始，再走[快速开始](../quickstart/)或[安装部署](../installation/)。下面一切都假设你已有一套运行中的部署。

## 如何使用本页

- **知道目标？** 跳到[按用例](#按用例)，找匹配的场景。
- **想要运维者的完整路径？** 按顺序读[按角色](#按角色)。
- **在贡献或调试系统本身？** 去[给贡献者](#给贡献者)。

## 按角色

| 角色 | 目标 | 阅读顺序 | 投入 |
|---|---|---|---|
| **新运维者** | 让一个 agent 在聊天频道里上线 | [介绍](../introduction/) → [快速开始](../quickstart/) → [安装部署](../installation/) → [Provider 与模型](../providers-and-models/) → [Agent](../agents/) → 某个 adapter 专页（如 [Lark](../adapters-lark/)） | 几小时 |
| **在岗运维者** | 日常配置、观察、运维部署 | [Console 运维操作](../console-operations/) → [Signal binding](../signal-bindings/) → [WorkerEnv secret](../worker-env/) → [调度](../schedules/) → [后台任务](../background-jobs-ops/) → [平台支持](../platform-support/) → [升级](../updating/) | 持续 |
| **安全 / 身份负责人** | 掌管管理员登录、directory 同步和权限 | [Principal 与 AuthZ](../principal-authz/) → [Console API 参考](../console-api/) → 所用 adapter 专页的 identity provider 部分 | 几小时 |
| **贡献者** | 开发 Ankole 本身 | [架构概览](../architecture/) → 开发者指南下的子系统页 → [kit CLI 参考](../kit-cli/) → [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md) | 数天 |

## 按用例

选匹配的场景。每个都按你应当阅读的顺序列出文档。

### "我想让一个 agent 在聊天频道里上线"

最常见的首次部署：一个在 Lark、Slack、钉钉、Microsoft 365 或 Google Workspace 里回答的 agent。

1. [安装部署](../installation/)——用 Compose 或 Helm 部署。
2. [Provider 与模型](../providers-and-models/)——给 agent 接上模型。
3. [Agent](../agents/)——创建 agent 并设人设。
4. [Signal binding](../signal-bindings/)——把 agent 接到一个 provider adapter。
5. 你所用平台的 adapter 专页：[Lark](../adapters-lark/)、[钉钉](../adapters-dingtalk/)、[Slack](../adapters-slack/)、[Microsoft 365](../adapters-microsoft-365/)、[Google Workspace](../adapters-google-workspace/)。
6. [FAQ](../faq/)——机器人不回复时，从第一个断掉的边界排查。

### "我想让管理员通过 identity provider 登录"

通过 Lark、Entra ID 或 Google Workspace 联合 Console 管理员访问。

1. [安装部署](../installation/)——完成首次产品设置，选择 identity provider。
2. [Principal 与 AuthZ](../principal-authz/)——管理员登录所处的权限模型。
3. 所用 adapter 专页的"identity provider"部分——[Lark](../adapters-lark/)、[Microsoft 365](../adapters-microsoft-365/)、[Google Workspace](../adapters-google-workspace/)。
4. [Console API 参考](../console-api/)——identity-provider 与 sync-runs 路由。

### "我想让 agent 在后台处理长任务"

把太长、步骤太多或隔离要求太高、无法就地跑的工作交出去。

1. [Agent](../agents/)——拥有这些任务的 agent。
2. [后台任务（运维视角）](../background-jobs-ops/)——状态、`waiting_on_user`、重试预算、取消。
3. [Background Agent Jobs](../background-agent-jobs/)——需要内部细节时的生命周期与恢复模型。

### "我想让 agent 按时间醒来"

给 agent 一个周期性节奏，或让它延迟后自唤醒。

1. [调度](../schedules/)——session 上的 cron schedule、暂停/恢复/手动运行、checkback。
2. [Signal binding](../signal-bindings/)——schedule 触发所走的 binding。

### "我想让 agent 跨回合和频道记忆"

给 agent 持久、经过复核的记忆。

1. [Brain](../brain/)——策展知识、召回、dreaming、监督。
2. [Console 运维操作](../console-operations/)——`/brain/*` 的读取与复核界面。

### "我想理解 Ankole 如何工作"

读系统，而非运维它。

1. [架构概览](../architecture/)——五个技术判断与组件地图。
2. [SignalsGateway](../signals-gateway/) → [Actor Runtime](../actor-runtime/) → [AIGateway](../ai-gateway/)——一条信号通往模型回合的路径。
3. [Brain](../brain/)、[Background Agent Jobs](../background-agent-jobs/)、[Agent Computer](../agent-computer/)、[Kernel](../kernel/)——各子系统。
4. [Principal 与 AuthZ](../principal-authz/)——权限边界。

## 给贡献者

为 Ankole 本身做贡献，与运维它是不同的目标。

1. [快速开始](../quickstart/)——从源码本地运行 Ankole。
2. [kit CLI 参考](../kit-cli/)——devkit 命令（`kit dev`、`kit app-db`、`kit analyze`）。
3. [架构概览](../architecture/)和开发者指南下的子系统页。
4. [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md)——设置、故障排查和验收的事实来源。
5. [`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md)——仓库范围的归属与纪律规则。

## 参考书架

当你需要的是事实，而非路径：

- [环境变量](../environment-variables/)——引导 env、运行时调优、AppConfigure 键。
- [kit CLI 参考](../kit-cli/)——每一条 `kit` 命令。
- [MCP server 参考](../mcp/)——MCP server 如何声明与加载。
- [Console API 参考](../console-api/)——REST 界面。
- [平台支持](../platform-support/)——受支持的部署目标与开发主机。
