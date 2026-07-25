---
title: Principal 与 AuthZ
description: 一套 Ankole 部署的权限边界——Principal 作为问责主体、permission grant、group 成员，以及运行时强制而非 prompt 约定。
section: Concepts
order: 11
---

Ankole 里的每一个动作——人类登录、agent 跑一个回合、一个任务唤醒它的 owner、一次 Brain 写入——都由一个 Principal 完成，而这个 Principal 能做什么，由 AuthZ 在动作发生的那一刻决定。本页对照 `Ankole.Principals` 和 `Ankole.AuthZ` 里的真实代码，画出这条边界。

先把决定性的性质说清楚：授权是运行时事实，在边界上强制，而不是去问模型的一条约定。Principal 是一个持久的、可问责的主体；它的 grant 在 PostgreSQL 里；每一个被检查的动作都由 kernel 针对一份显式快照求值，给出一个调用方必须遵从的决定。

## Principal：一个问责主体

Principal 是人类、agent 和安装服务共用的持久问责主体。`principals` 表以 `uid`（一种有类型的 `PrincipalKey`，由 check 约束强制小写且非空）为主键，每一行带一个 `type`——`:human`、`:agent` 或 `:system`——和一个 `status`：`:active` 或 `:disabled`。

一个人类 Principal 有一个 `HumanUser` 和任意数量的 `ExternalIdentity` 行（运维者联合进来的那些身份）。一个 agent Principal 有一个 `Agent` 行。把两者都收进同一张表的意义在于，问责只有一种形态：无论谁做了那件事，都有一个 Principal 行做了它，并且它有一个稳定的 uid，每一行审计、每一份 grant、每一条 group 成员都指向它。

一个被禁用的 Principal 不是“部分可用”。kernel 的决定对一个被禁用的主体返回 `principal_disabled`，所以禁用一个 Principal 会跨整套部署移除它的权限，而不必逐条去追它的每一份 grant。

## grant：谁能做什么

一份 permission grant 恰好归一个 Principal，或恰好归一个 Principal group——不能两者皆有，也不能两者皆无，由 `validate_owner_shape` 和一条数据库 check 约束强制。一份 grant 带着：

- 一个 `resource_pattern`——这份 grant 覆盖什么，语法由 `Input.validate_resource_pattern_syntax` 校验；
- 一个 `action`——这份 grant 允许什么，不允许含冒号（冒号留给 resource/action 的分隔）；
- 一个 `condition`——一个布尔表达式，默认 `"true"`，由 `Input.validate_condition_syntax` 校验；
- 一份 `description` 和 `metadata`，供运维者阅读。

grant 在语义上是追加式的，并按 owner 自然键唯一（每个 Principal 一份，每个 group 一份，落在自然索引上）。创建、upsert、更新 grant 都是控制面操作；调用方构造不出一份指向数据库会拒绝的 owner 形态的 grant。

## group：静态与计算式成员

一个 Principal group 是一个命名的集合，Principal 可以通过它被授权，这样权限就能扩展，而不必为每个 Principal 建行。一个 group 有一个 `domain`——`:operator`、`:directory` 或 `:im_group`——一种 `kind`：`:static` 或 `:computed`，以及计算式 group 的一个可选 `computed_condition`。

两个内置 group 为部署播种。`admin` group 是运维者的权限界面。`all_humans` group 带着计算条件 `principal.type == "human" && principal.status == "active"`，所以每个活跃人类都是成员，而不必有人手工维护这份名单。静态成员住在 `principal_group_memberships` 里；计算式成员针对快照求值。外部目录（一个 IdP、一个 IM 平台）可以通过 external binding 同步进 group，于是运维者可以把 AuthZ 指向它已经信任的那个目录。

## 一个决定是如何做出的

控制面和 kernel 刻意分担这项工作，而这种分担正是 AuthZ 可强制、而非仅供参考的原因：

- **控制面拥有状态和快照装配。** 对一个被检查的动作，它加载 Principal、它的 grant、它的 group 成员，以及相关的 resource 上下文，装配出一份显式的授权快照。
- **kernel 拥有确定性的规则求值。** 它对快照里的 grant 和 condition 求值，返回一个决定。因为输入是一份显式快照、规则是确定性的，同一份快照每次都给出同一个答案，没有任何内存缓存能 drifting。

公开入口是 `AuthZ.authorize(principal_uid, resource, action, context)`、返回布尔的 `allowed?/4`、针对一个 resource 上一批 action 的 `authorize_all`，以及返回完整决定 map 的 `_decision` 变体。每一个都装配一份快照交给 kernel；没有任何一个信任调用方关于 Principal 能做什么的自述。

## 决定状态

一个决定以四种状态之一回来，每一种都对应调用方的一项义务：

- **`allow`**——动作被允许；继续。
- **`deny`**——动作被禁止，并点出 `deniedAction`。调用方不得执行。
- **`principal_disabled`**——主体被禁用。当作一次带具体原因的拒绝。
- **`invalid_request`**——请求本身畸形。调用方去修请求，而不是盲目重试。

每次决定都会发出诊断，所以一次拒绝是可观测的。`AuthZ.result/1` 把一个决定变成 `:ok | {:error, reason}`，这就是调用方据以分支的形态。

## 强制实际发生在哪里

AuthZ 不是 agent 能绕开的一层，因为运行时在那些要紧的边界上咨询它：

- AIGateway 从一个经验证的 token 解析出每次调用的主体，而该主体的 grant 决定它能触及哪些 model 选择符和 provider。
- Actor Runtime 用 agent Principal 拥有的 activation 为每个回合设隔离栏；来自任何其他主体的回复会撞上隔离栏失败。
- Brain 通过会话声明和 owner Principal 为每次读写划定 scope；一次写入的权限模式从 actor 推导，而不是从载荷推导。
- Console 操作走一个经验证的管理员 token，而管理员 Principal 的 group 成员决定它能改什么。

模型永远没有机会主张“我被允许”。边界核对 Principal 和 grant，并按决定行动。

## 运维界面

console 范围的路由暴露 AuthZ 模型供查看和管理：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/principals` | 列出 Principal |
| `GET` | `/principals/:uid` | 读取一个 Principal |
| `GET` | `/principals/:uid/groups` | 列出一个 Principal 的 group |
| `GET` | `/principals/:uid/grants` | 列出一个 Principal 的 grant |
| `GET` | `/principal-groups` | 列出 group |
| `POST` | `/principal-groups` | 创建一个 group |
| `GET` | `/principal-groups/:name` | 读取一个 group |
| `PATCH` | `/principal-groups/:name` | 更新一个 group |
| `POST` | `/principal-groups/computed-member-previews` | 预览一个计算式 group 的成员 |

管理 grant 和成员都走 AuthZ facade，它在写入任何行之前校验 owner 形态、resource pattern 语法和 condition 语法。数据库的 check 约束是兜底：违反 owner 形态或禁冒号规则的行根本无法存在。

## Principal 和 AuthZ 不是什么

AuthZ 不是一条 prompt 指令，也不是一种期望。它不去要求模型负责任；它核对 Principal 并强制执行答案。Principal 不是多租户垫片，也不是按请求分配的角色——它是一个稳定的、可问责的主体，其权限被授予、分组、求值。kernel 也不是运维者配置的第二个策略引擎；它是控制面装配出的那份快照之上的确定性求值器。边界是干净的：状态在这里，求值在那里，一个调用方必须遵从的决定。

## 下一步

- 一个经验证的 token 如何在 AIGateway 边缘解析成 Principal，读 [AIGateway API](../ai-gateway/)。
- agent Principal 的 activation 如何为一个回合设隔离栏，读 [Actor Runtime](../actor-runtime/)。
- Brain 如何从 actor 推导写入权限，读 [Brain](../brain/)。
