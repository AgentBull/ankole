---
title: 常见问题与故障排查
description: 常见问题的简短回答，以及本地 Ankole 环境启动不了时该先看哪里。
section: Getting started
order: 5
---

最常见问题的简短回答，加上一条本地环境起不来时的排查顺序。仓库的 [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md) 仍然是更深一层的事实来源——本页在要紧的地方指向它。

## 常见问题

### Ankole 是聊天机器人后端吗？

不是。聊天机器人优化的是“单次回答”，Ankole 优化的是“这个岗位”：一个 agent 守住一件正在进行的工作，读懂共享上下文，并接受结果的检验。这套运行时更接近面向长时 AI 工作的分布式操作系统，而不是请求/响应后端。完整模型见[架构概览](../architecture/)。

### 我的数据会被发到哪里去吗？

模型调用只会发往你配置的 LLM provider。记忆、配置、凭证和审计都在你自己的基础设施里，在你自己的控制面背后。除了你指向 provider 的流量，不会有任何东西离开这套部署。

### 一套自托管部署需要什么？

一个控制面、一个或多个 Agent Computer Worker、PostgreSQL 18 或更高版本（预加载 `pg_search`），以及持久化的 Agent Home 存储。两种受支持的部署包——单机的 Docker Compose、Kubernetes 的 Helm——已经把这几样都打包好了。详见[安装部署指南](../installation/)。

### 能从多个入口驱动 agent 吗？

能。有三类一等入口：共享工作从 SignalsGateway 进入（聊天、webhook、定时任务）；应用和企业系统通过 OpenResponses 兼容的 HTTP、SSE、WebSocket API 直接调用 AIGateway；运维者通过 Console 和 API 介入。

### worker 重启后 agent 还在吗？

在。一个 session 是一个虚拟 actor，在 PostgreSQL 里有持久邮箱、检查点和恢复路径。后台 Agent 任务能熬过 worker 丢失，可以继续、可以等待输入，并在状态变化时唤醒它的 owner 会话。Worker 是可替换的执行底座，不是事实的来源。

### 公共 API 有兼容性承诺吗？

还没有。公共 API 已经在生产环境端到端可用，但目前并不带有兼容性承诺，在此之前版本之间会有破坏性变更。

## 从第一个断掉的边界开始排查

永远从 `bun dev` 终端里的第一个错误看起。后面的错误往往是更早一次编译、数据库、端口或 worker 失败的后果——先追第二个错误只会浪费时间。

### Docker 或 PostgreSQL 起不来

```bash
docker info
bun run services:status
docker ps --filter name=ankole
```

先启动 Docker Desktop，或修好 Linux 上的 Docker 权限，再去动项目代码。不要因为一次启动失败就删 Docker 卷。

### 本地数据库确实坏了、且可以丢弃

重建命令会删除本地的 `ankole_dev` 数据库。只有在确认数据可以丢失之后，才能执行：

```bash
bun run kit app-db rebuild --yes
bun run control-plane:setup
```

一次 migration 失败、或一个不眼熟的 Ecto 报错，都不能当成自动重建数据库的理由。

### 页面打不开

```bash
curl -I http://localhost:4000/
lsof -nP -iTCP:4000 -sTCP:LISTEN
lsof -nP -iTCP:3035 -sTCP:LISTEN
lsof -nP -iTCP:6010 -sTCP:LISTEN
```

先解决第一个进程冲突或编译失败。不要在没同步更新所有依赖回调和 worker 端点的情况下改动文档约定的端口。

### 找不到 activation code

在页面上点重新打印，读 `bun dev` 终端，然后再退回到：

```bash
bun run kit show bootstrap-activation-code
```

不要从浏览器内部或数据库行里猜 code。

### 飞书报回调地址不匹配

setup 的身份步骤会显示这套部署要登记的登录回调地址，跳转之前就能看到。把它原样填进 provider 的开发者后台。它由控制面看到的请求 origin 加上 provider ID 组成，本地默认是：

```text
http://localhost:4000/sessions/oidc/lark-main/callback
```

改了 Provider ID，这个地址就跟着变，provider 那边也要一起改。

### 钉钉登录报「应用不存在」

这是钉钉登录服务解析不出这个 Client ID，错误码 900103。它在跳转的一瞬间就出现，说明请求还没走到回调地址那一步——所以先别怀疑回调地址。按顺序查：

1. 填的是应用的 **Client ID**（在开发者后台「基础信息 → 凭证与基础信息」），不是 AgentId、robotCode，也不是群自定义机器人的 webhook token。
2. 应用已经开通了 Ankole 要调的权限点：`Contact.User.Read`（登录取个人信息，要手机号再加 `Contact.User.mobile`）、`qyapi_get_member`、`qyapi_get_department_list`、`qyapi_get_department_member`，以及手机号和邮箱的字段权限。缺权限时钉钉的服务端接口会回 sub_code `60011` 并给出申请链接。
3. 权限或配置改完，去「应用发布 → 版本管理与发布」发一个版本。没发布，改动不生效。

凭据本身有效并不能排除这个错误：Client ID 和 Client Secret 能换到应用 token，登录页仍然可能报「应用不存在」。setup 在跳转前会验一次凭据，所以如果表单没有报错、跳过去仍然是「应用不存在」，问题就在应用的权限或发布状态上，不在填的值上。

### 钉钉登录扫完码才报回调地址错

钉钉打开授权页时不校验 `redirect_uri`，要等用户扫码并同意授权之后才校验。所以回调地址必须在第一次登录之前就登记到「开发配置 → 安全设置 → 重定向URL（回调域名）」，地址就是 setup 身份步骤显示的那一条。

### 登录成功，但机器人不回复

按顺序排查这些边界：

1. 最新版飞书应用已发布，且机器人能力已开启。
2. 测试用户和会话在范围内，机器人在该会话里。
3. 消息、CardKit、事件和回调权限都已激活。
4. Signal binding 已启用，并指向目标 agent。
5. agent 有可用的 model profile，provider 凭证有效。
6. `local-dev-worker` 已就绪。

查看 worker 最近的输出，但不要把它的环境变量打印出来：

```bash
docker logs --tail 200 ankole-dev-agent-computer
```

如果主 model profile 不可用，先去看 Console 的 Agents 和 Providers 页面，再去怀疑飞书入口。

### 刚保存的 worker secret 不生效

Worker 环境的改动会在新的回合里注入。保存之后发一条新消息，不要用一个已经在跑的回合来判断这次改动。

## 下一步

- 完整的环境、设置和验收细节，见 [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md)。
- 生产部署见[安装部署指南](../installation/)。
