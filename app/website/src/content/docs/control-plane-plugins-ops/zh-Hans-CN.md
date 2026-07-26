---
title: Control Plane Plugin 运维
description: 如何通过 Console 启用、禁用和检查 Control Plane Plugin——下次启动模型以及变更前后要检查什么。
section: User guide
order: 56
---

Control Plane Plugin 用第一方 Elixir 模块扩展控制面——signal adapter、identity provider、AppConfigure 键、受监督子进程。运维者的工作是启用和禁用它们，并理解变更何时生效。本页是那个面的任务导向视角。

先把决定性的性质说清楚：plugin 激活在**下次进程启动**时生效，不是立即。这是刻意的——激活或停用 plugin 会增删受监督子进程和配置键，这是启动时的事。你通过 Console 排定变更；重启落实它。

## 列出 plugin

```bash
curl https://ankole.example.com/api/v1/control-plane-plugins \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /control-plane-plugins` 返回每个已发现的 plugin——其 id、显示名、描述和两个状态：

- **已发现**——plugin 编译进发布、在目录中可见。每个已发现的 plugin 都在这里出现，不论是否已启用。
- **已激活**——plugin 在全局启用清单中，将在下次启动时贡献其配置和子进程（或若当前进程启动时已启用，则已在贡献）。

响应并排显示两个状态，让你区分当前已激活的和已为下次启动排定的。

## 启用或禁用 plugin

```bash
curl -X PUT https://ankole.example.com/api/v1/control-plane-plugins \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "id": "lark-adapter", "enabled": true }'
```

`PUT /control-plane-plugins` 为下次启动排定一个 plugin。响应显示更新后的状态——下次重启后将激活什么。变更在控制面重启前不生效。

## 变更何时生效

`PUT` 后重启控制面：

```bash
# Compose
docker compose restart control-plane

# Helm
kubectl -n ankole rollout restart deployment/ankole-control-plane
```

重启时，注册表读取启用清单、激活已启用的 plugin、注册其 AppConfigure 键、启动其受监督子进程。被禁用的 plugin 的子进程被停止、键被取消注册。

若 plugin 在激活期间失败（配置坏、缺依赖、唯一性冲突），注册表的 `init` 返回 `:stop`，在系统带着只注册了一半的 plugin 集运行之前中止应用启动。失败大声，不沉默。

## 启用前检查什么

- **plugin 的配置就绪了吗？** 一些 plugin 需要 AppConfigure 键或 adapter 凭证才能工作。查 plugin 文档或 adapter 专页。
- **plugin 需要网络路径吗？** 使用长连接的 signal adapter 需要出站互联网；webhook handler 需要公共入口。确认部署有 plugin 所需的路径。
- **有冲突吗？** 两个声明同一 adapter id 或同一配置键的 plugin 冲突。注册表在启动时拒绝第二个。

## 启用后检查什么

- **控制面干净启动了吗？** 读启动日志看 plugin 初始化错误。
- **plugin 的契约面可见了吗？** signal adapter 应出现在 `GET /signal-adapters`；identity provider 应出现在 `GET /identity-provider-adapters`。
- **真实往返管用吗？** 通过新启用的 adapter 发测试消息或触发测试登录。

## 本指南不是什么

它不是 plugin 概念页——已发现/已激活模型、契约、第一方扩展设计见 [Control Plane Plugins](../control-plane-plugins/)。它不是 plugin 编写指南——写 plugin 见[创建 Control Plane Plugin](../creating-a-control-plane-plugin/)。它不是部署指南——重启控制面见[升级](../updating/)或[安装部署](../installation/)。

## 下一步

- 概念页，读 [Control Plane Plugins](../control-plane-plugins/)。
- 写 plugin，读[创建 Control Plane Plugin](../creating-a-control-plane-plugin/)。
- 重启，读[升级](../updating/)。
- Console 路由，读 [Console API 参考](../console-api/)。
