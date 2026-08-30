---
title: 主体与 AuthZ
description: Ankole 实例的权限边界，包括主体、授权规则、权限组成员关系和运行时权限检查。
section: Developer guide
order: 106
---

Ankole 中的每个动作都有明确的主体：人员登录、Agent 运行一个回合、任务唤醒所有者。主体能做什么，由 AuthZ 在动作发生时决定。本页以 `Ankole.Principals` 和 `Ankole.AuthZ` 的实际代码为准说明这条边界。

授权是运行时事实，由系统边界强制执行，不是写给模型的一条约定。主体（Principal）是持久、可问责的身份；授权规则存储在 PostgreSQL 中。每个受检查的动作都由 Kernel 根据明确的快照求值，调用方必须服从求值结果。

## 主体：统一的问责身份

人员、Agent 和实例内的系统服务都使用同一种持久主体。`principals` 表以 `uid` 为主键；这个 UID 使用有类型的 `PrincipalKey`，并由 Check 约束保证非空且为小写。每条记录包含类型 `:human`、`:agent` 或 `:system`，以及状态 `:active` 或 `:disabled`。

人员主体对应一条 `HumanUser` 记录和任意数量的 `ExternalIdentity` 记录；Agent 主体对应一条 `Agent` 记录。把它们放在同一张主体表中，意味着系统只有一种问责方式：每个动作都能追溯到一个稳定 UID，审计记录、授权规则和权限组成员关系都引用这个 UID。

被停用的主体不是“部分可用”。Kernel 会为它返回 `principal_disabled`，所以停用一个主体会在整个实例内撤销它的权限，不必逐条删除每一份授权。

## grant：谁能做什么

一条授权规则只归属于一个主体或一个权限组，不能同时属于两者，也不能没有所有者。`validate_owner_shape` 和数据库 Check 约束共同保证这个条件。一条授权规则包含：

- 一个 `resource_pattern`——这份 grant 覆盖什么，语法由 `Input.validate_resource_pattern_syntax` 校验；
- 一个 `action`——这份 grant 允许什么，不允许含冒号（冒号留给 resource/action 的分隔）；
- 一个 `condition`——一个布尔表达式，默认 `"true"`，由 `Input.validate_condition_syntax` 校验；
- 一份 `description` 和 `metadata`，供运维者阅读。

授权规则按所有者自然键保持唯一，主体和权限组分别使用对应的自然索引。创建、Upsert 和更新授权规则都由控制面完成；数据库会拒绝所有者结构无效的记录。

## group：静态与计算式成员

权限组是一组具名主体。把授权规则授予权限组后，不必为每个主体分别创建记录。权限组包含 `domain`（`:operator`、`:directory` 或 `:im_group`）、`kind`（`:static` 或 `:computed`），以及动态组可选的 `computed_condition`。

两个内置 group 随部署预置。`admin` group 是运维者的权限界面。`all_humans` group 带着计算条件 `principal.type == "human" && principal.status == "active"`，所以每个活跃人类都是成员，而不必有人手工维护这份名单。静态成员存放在 `principal_group_memberships` 里；计算式成员针对快照求值。外部目录（一个 IdP、一个 IM 平台）可以通过 external binding 同步进 group，于是运维者可以把 AuthZ 指向它已经信任的那个目录。

## 一个决定是如何做出的

控制面和 kernel 刻意分担这项工作，而这种分担正是 AuthZ 可强制、而非仅供参考的原因：

- **控制面拥有状态并组装快照。** 对每个需要检查的动作，控制面加载主体、授权规则、权限组成员关系和相关资源上下文，组装出明确的授权快照。
- **kernel 拥有确定性的规则求值。** 它对快照里的 grant 和 condition 求值，返回一个决定。因为输入是一份显式快照、规则是确定性的，同一份快照每次都给出同一个答案，没有任何内存缓存能漂移。

公开入口包括 `AuthZ.authorize(principal_uid, resource, action, context)`、返回布尔值的 `allowed?/4`、批量检查资源动作的 `authorize_all`，以及返回完整决策 Map 的 `_decision` 变体。每个入口都会组装快照并交给 Kernel 求值，不会信任调用方对主体权限的自述。

## 决定状态

一个决定以四种状态之一回来，每一种都对应调用方的一项义务：

- **`allow`**——动作被允许；继续。
- **`deny`**——动作被禁止，并点出 `deniedAction`。调用方不得执行。
- **`principal_disabled`**——主体被禁用。当作一次带具体原因的拒绝。
- **`invalid_request`**——请求本身畸形。调用方去修请求，而不是盲目重试。

每次决定都会发出诊断，所以一次拒绝是可观测的。`AuthZ.result/1` 把一个决定变成 `:ok | {:error, reason}`，这就是调用方据以分支的形态。

## 强制实际发生在哪里

AuthZ 不是 agent 能绕开的一层，因为运行时在关键边界上都会咨询它：

- AIGateway 从一个经验证的 token 解析出每次调用的主体，而该主体的 grant 决定它能触及哪些 model 选择符和 provider。
- Actor Runtime 使用 Agent 主体拥有的 Activation 为每个回合设置隔离栏；来自其他主体的回复会被拒绝。
- Console 操作使用已经验证的管理员 Token，管理员主体所在的权限组决定它可以修改什么。

模型没有机会自行声明“我有权限”。系统边界会核对主体和授权规则，并落实求值结果。

## 运维界面

console 范围的路由暴露 AuthZ 模型供查看和管理：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/principals` | 列出主体 |
| `GET` | `/principals/:uid` | 读取一个主体 |
| `GET` | `/principals/:uid/groups` | 列出一个主体所属的权限组 |
| `GET` | `/principals/:uid/grants` | 列出一个主体的授权规则 |
| `GET` | `/principal-groups` | 列出 group |
| `POST` | `/principal-groups` | 创建一个 group |
| `GET` | `/principal-groups/:name` | 读取一个 group |
| `PATCH` | `/principal-groups/:name` | 更新一个 group |
| `POST` | `/principal-groups/computed-member-previews` | 预览一个计算式 group 的成员 |

管理 grant 和成员都走 AuthZ facade，它在写入任何行之前校验 owner 形态、resource pattern 语法和 condition 语法。数据库的 check 约束是最后防线：违反 owner 形态或禁冒号规则的行根本无法存在。

## 主体和 AuthZ 不是什么

AuthZ 不是 Prompt 指令，也不是对模型的期望。它核对主体并强制执行求值结果。主体不是用来在一个实例内划分企业边界的临时字段，也不是按请求分配的角色；它是稳定、可问责的身份，可以被授权、分组和求值。Kernel 也不是第二套策略引擎，只对控制面组装的快照执行确定性求值。控制面管理状态，Kernel 负责求值，调用方必须执行结果。

## 下一步

- 经过验证的 Token 怎样在 AIGateway 边缘解析成主体，见 [AIGateway API](../ai-gateway/)。
- Agent 主体的 Activation 怎样为一个回合设置隔离栏，见 [Actor Runtime](../actor-runtime/)。
