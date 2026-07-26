---
title: Principal 与 group
description: AuthZ 的任务导向运维视角——列出 Principal、管理 group、分配成员、创建和查看权限授予。
section: User guide
order: 49
---

Principal 是能在 Ankole 里行动的人；group 是你限定其权限范围的方式；grant 是它们能做什么。本页是权限面的任务导向运维视角——管理 Principal、group、成员和 grant 的路由，附完整示例。它以具体操作补充 [Principal 与 AuthZ](../principal-authz/) 概念页。

先把决定性的性质说清楚：grant 恰好归一个 Principal 或一个 group——不能两者皆有，不能两者皆无。group 上的 grant 到达该 group 的每个成员；Principal 上的 grant 只到达该 Principal。权限按团队成员身份扩展时用 group；一个 Principal 需要独特的东西时用直接 Principal grant。

## 列出 Principal

```bash
curl https://ankole.example.com/api/v1/principals \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /principals` 列出每个 Principal——人类、agent 和系统服务。用 `GET /principals/:uid` 读取一个，含其 type（`human`/`agent`/`system`）和 status（`active`/`disabled`）。被禁用的 Principal 跨部署立即失去权限——用它撤销访问而不删除 Principal。

## 列出 Principal 的 group 和 grant

```bash
curl https://ankole.example.com/api/v1/principals/<uid>/groups -H "Authorization: Bearer $CONSOLE_TOKEN"
curl https://ankole.example.com/api/v1/principals/<uid>/grants -H "Authorization: Bearer $CONSOLE_TOKEN"
```

group 列表显示该 Principal 属于哪些 AuthZ group（静态成员、计算式成员、已同步 directory group）。grant 列表显示该 Principal 直接拥有的每个权限授予——不含通过 group 成员身份继承的 grant。

## 管理 group

```bash
# 列出 group
curl https://ankole.example.com/api/v1/principal-groups -H "Authorization: Bearer $CONSOLE_TOKEN"

# 创建 group
curl -X POST https://ankole.example.com/api/v1/principal-groups \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "name": "on-call", "domain": "operator" }'

# 读取 group
curl https://ankole.example.com/api/v1/principal-groups/on-call -H "Authorization: Bearer $CONSOLE_TOKEN"
```

group 带 `domain`——`operator`（你管理）、`directory`（从 IdP 同步）、`im_group`（从聊天平台）。operator-domain group 是你直接管理的；directory group 由 IdP 同步管理。

## 管理 group 成员

```bash
# 添加成员
curl -X PUT https://ankole.example.com/api/v1/principal-groups/on-call/members/<principal_uid> \
  -H "Authorization: Bearer $CONSOLE_TOKEN"

# 移除成员
curl -X DELETE https://ankole.example.com/api/v1/principal-groups/on-call/members/<principal_uid> \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

把成员加进 group 立即授予他们该 group 的 grant 允许的每一项权限。移除则撤销。对于 directory 同步的 group，在来源 directory 管理成员身份——同步传播变更。

## 管理权限授予

```bash
# 在 group 上创建 grant
curl -X POST https://ankole.example.com/api/v1/permission-grants \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "group_id": "<group-uuid>",
    "resource_pattern": "agent:agent-1",
    "action": "read"
  }'

# 读取 grant
curl https://ankole.example.com/api/v1/permission-grants/<id> -H "Authorization: Bearer $CONSOLE_TOKEN"

# 更新 grant
curl -X PATCH https://ankole.example.com/api/v1/permission-grants/<id> \
  -H "..." -d '{ "condition": "true" }'

# 删除 grant
curl -X DELETE https://ankole.example.com/api/v1/permission-grants/<id> \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

grant 带 `resource_pattern`（应用到什么）、`action`（允许什么）、`condition`（一个 CEL 布尔，默认 `true`）。`resource_pattern` 用模式语法；`action` 不得含冒号（冒号在 kernel 里分隔 resource 和 action）。设 owner 为 group（`group_id`）或 Principal（`principal_uid`）——不能两者都有。

## 一个完整示例

给 on-call 团队对特定 agent 的读权限：

1. 创建 group `on-call`（domain: `operator`）。
2. 把 on-call 的人加为成员（`PUT .../members/<uid>`）。
3. 在 group 上创建 grant：`resource_pattern: "agent:agent-1"`、`action: "read"`。
4. `on-call` 的每个成员现在都能读那个 agent——通过 `GET /principals/<uid>/groups` 验证。

## 本指南不是什么

它不是概念页——Principal/AuthZ 模型、决定状态、kernel 求值见 [Principal 与 AuthZ](../principal-authz/)。它不是 directory 同步指南——directory group 如何到达见 [Identity provider](../identity-providers/)。它不是安全加固指南——最小权限姿态见[安全加固](../security-hardening/)。

## 下一步

- 概念页，读 [Principal 与 AuthZ](../principal-authz/)。
- directory 同步的 group，读 [Identity provider](../identity-providers/)。
- 最小权限姿态，读[安全加固](../security-hardening/)。
- Console 路由，读 [Console API 参考](../console-api/)。
