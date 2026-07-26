---
title: 创建 Control Plane Plugin
description: 如何编写一个第一方 Elixir plugin，向控制面贡献 signal adapter、identity provider、AppConfigure 键或受监督子进程。
section: Developer guide
order: 113
---

Control Plane Plugin 是 Elixir 控制面的第一方扩展面。本页是贡献者 walkthrough：回调契约、最小的 plugin、接入子系统契约的声明、让 plugin 被发现的注册。它建立在 [Control Plane Plugins](../control-plane-plugins/) 概念页之上；本页是*如何写一个*。

先把决定性的性质说清楚：plugin 是编译进发布的 Elixir 模块，在 `config/config.exs` 中注册，启动时被发现。没有 marketplace、没有热加载、没有第三方打包——plugin 是通过契约声明了自己的第一方代码。像写控制面里任何模块一样写它。

## 回调契约

plugin 针对 `Ankole.Plugins.Plugin` 实现回调。只有一个必需；其余可选，默认为空或 nil：

| 回调 | 必需 | 返回 |
|---|---|---|
| `plugin_id/0` | 是 | 一个小写 slug（`~r/\A[a-z][a-z0-9_-]*\z/`） |
| `display_name/0` | 否 | 本地化文本，或 nil |
| `description/0` | 否 | 本地化文本，或 nil |
| `app_config_definitions/0` | 否 | AppConfigure `Definition` 结构体列表 |
| `app_config_patterns/0` | 否 | AppConfigure `PatternDefinition` 结构体列表 |
| `adapter_declarations/0` | 否 | adapter 声明 map 列表 |
| `children/0` | 否 | `Supervisor.child_spec` 列表 |

`Spec.from_module/1` 在启动时读取这些回调，归一化为一个 `Spec`。对 plugin 自有形态（身份、本地化文本、AppConfigure 声明、子进程、adapter 声明信封）校验严格，错误连同出问题的模块一起包装，所以启动失败指向负有责任的 plugin。

## 最小的 plugin

```elixir
defmodule Ankole.Plugins.MyPlugin do
  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "my-plugin"
end
```

这是一个完整、合法的 plugin。它不声明任何东西、不贡献任何东西、被注册表列出。它是起点——按 plugin 需要贡献的加回调。

## 注册 plugin

把模块加到 `config/config.exs` 的 plugin 清单里：

```elixir
config :ankole, :control_plane_plugin_modules, [
  # ...已有 plugin...
  Ankole.Plugins.MyPlugin
]
```

注册表启动时读这个清单。plugin 出现在 `GET /control-plane-plugins` 里为已发现；通过 Console 启用它使其激活（注册其 AppConfigure 键、启动其子进程）。

## 声明 adapter（signal adapter 或 identity provider）

`adapter_declarations/0` 回调返回 adapter 声明 map，每个把 plugin 接入一个子系统契约。契约 id 命名子系统：

```elixir
@impl true
def adapter_declarations do
  [
    %{
      contract_id: "signals_gateway.adapter",
      id: "my-adapter",
      plugin_id: plugin_id(),
      # ...adapter 专属字段、module、config_key_pattern...
    }
  ]
end
```

契约专属字段（`config_module`、`binding_saved_module`、`worker_env_module` 等）由消费该契约的子系统解释——`signals_gateway.adapter` 由 `SignalsGateway.Adapters` 消费、`principals.identity_provider` 由 identity-provider 注册表消费。plugin 注册表只持有通用信封；子系统是聪明的消费者。adapter 声明如何被消费见 [SignalsGateway](../signals-gateway/) 开发者页。

## 贡献 AppConfigure 键

`app_config_definitions/0` 回调返回 plugin 贡献的运维者管理键的 `Definition` 结构体。plugin 激活时注册它们，它们出现在 Console 的 AppConfigure 界面：

```elixir
@impl true
def app_config_definitions do
  [
    AppConfigure.define(
      key: "my_plugin.setting",
      encrypted: false,
      schema: Schema.string(),
      scope: :global,
      default_value: "default",
      description: "我的 plugin 在运行时读取的一个设置。"
    )
  ]
end
```

用 `app_config_patterns/0` 存加密配置 pattern——例如 provider 凭证块的形态。引导 env 与 AppConfigure 键的区别见[环境变量](../environment-variables/)；plugin 的键始终是 AppConfigure，不是引导 env。

## 贡献受监督子进程

`children/0` 回调返回 plugin 激活时想启动的子进程规格——一个拥有长连接的 `GenServer`、一个 `Registry`、一个定期调和器。它们跑在 plugin 的监督树下，启用时启动、禁用时停止（下次进程启动）。

## 生命周期：已发现，然后已激活

注册表在 `init/1` 里一次性解析全部 plugin 集合。plugin 从注册起即**已发现**（运维者看到的目录里）；只有进入全局启用清单才**已激活**（配置注册、子进程启动）。启用是 Console 操作；激活在下次进程启动生效。为什么激活是启动时的事见 [Control Plane Plugins](../control-plane-plugins/)。

## 本指南不是什么

它不是 Elixir 或 OTP 教程——像写控制面里任何模块一样写 plugin。它不是运送第三方或热加载代码的方式；模型是第一方、编译进、启动激活。它也不是子系统页的替代；adapter 声明的确切字段由消费它们的子系本文档，不是本页。

## 下一步

- 概念页（已发现 vs 已激活、启用边界），读 [Control Plane Plugins](../control-plane-plugins/)。
- signal adapter 声明如何被消费，读 [SignalsGateway](../signals-gateway/)。
- plugin 贡献的 AppConfigure 键，读[环境变量](../environment-variables/)。
