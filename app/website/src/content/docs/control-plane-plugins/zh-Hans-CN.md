---
title: Control Plane Plugins
description: 第一方 Elixir 扩展模型——已发现与已激活的 plugin、子系统契约、AppConfigure 键、受监督子进程，以及下一次启动才生效的启用边界。
section: Developer guide
order: 110
---

Control Plane Plugin 是 Ankole 实例扩展控制面的方式。插件可以提供信号适配器、身份源提供商、AppConfigure 配置键或受监督进程，不必把每种接入写成控制面中的一次性代码路径。本页以 `Ankole.Plugins` 的实际代码为准说明这套模型。

先说明最关键的一点：这些是编译进发布的第一方 Elixir 模块，不是可安装扩展的 marketplace。一个 plugin 在启动时被发现并校验，通过一个全局启用清单被选用，并且只在下一次进程启动时激活。没有热加载、没有第三方发现、没有隔离机制——这是刻意的。

## 两个阶段，含义不同

一个 plugin 的生命周期有两个阶段，这一区分是承重的：

- **已发现（discovered）**——启动时找到并校验过的每一个 plugin 模块。这是运维者能看到的完整目录，不论它是否已启用。
- **已激活（active）**——那些进入全局启用清单的已发现 plugin。只有已激活的 plugin 才会注册它的 AppConfigure 键并启动它的受监督子进程。

一个已发现但未激活的 plugin 是可见的，但不做事。它的声明不会到达本会消费它的那些子系统，它的子进程也不跑。这正是让运维者能在决定启用之前，先把整个目录看一遍的设计。

## plugin 契约

一个 plugin 是一个 Elixir 模块，它针对 `Ankole.Plugins.Plugin` 实现一小组回调。只有一个必需：

- **`plugin_id/0`**——plugin 的身份，一个小写 slug，匹配 `~r/\A[a-z][a-z0-9_-]*\z/`。

其余都是可选的，模块不导出时默认为空或 nil：

- **`display_name/0`**、**`description/0`**——供运维界面使用的本地化文本。
- **`app_config_definitions/0`**、**`app_config_patterns/0`**——plugin 贡献的 AppConfigure 键。
- **`adapter_declarations/0`**——让一个 plugin 接入某个子系统契约的通用信封。
- **`children/0`**——plugin 希望启动的受监督子进程规格。

`Spec.from_module/1` 在启动时读取这些回调，并把结果归一化为一个 `Spec`。对 plugin 自有的形态——身份、本地化文本、AppConfigure 声明、子进程、adapter 声明信封——校验是严格的，并且错误会连同出问题的模块一起给出，所以一次启动失败会指向那个负有责任的 plugin。

## 子系统契约

一个 plugin 通过一个具名契约接入某个子系统，契约 id 允许含点号，这样子系统可以为契约加命名空间。实际在用的契约：

- **`signals_gateway.adapter`**——声明一个 Signal adapter，SignalsGateway 会把它解析进自己的 adapter 注册表。一个新的聊天或事件 provider 就这样成为一个可绑定的目标。
- **`signals_gateway.webhook_handler`**——为 `/webhooks/v1/:handler_id/:instance_id/:kind` 这扇正门声明一个 handler。handler 负责 provider 鉴权，并用一条归一化事实调用入口。
- **`principals.identity_provider`**——声明一个身份源提供商，供运维者配置管理员登录。

契约相关的回调语义，由消费该契约的子系统定义。plugin 注册表只持有通用的 adapter 声明信封；子系统（例如 `SignalsGateway.Adapters`）读取属于自己契约 id 的那些声明，并解释它们。这种分离让注册表是一个简单的目录，而子系统是聪明的消费方。

## 启用边界：下一次进程启动

Plugin 对整个实例生效，并在启动失败时保持关闭。因此，运维者通过 PostgreSQL 中的 AppConfigure 键 `plugins.enabled_ids` 明确选择要启用的插件。控制面启动时，注册表会在 `init/1` 中读取一次这份清单。

改动这份启用清单**不会**立即生效。它在下一次 Ankole 进程启动时生效。这是刻意的。激活或停用一个 plugin 会增删受监督子进程和配置键，这是一件启动时的事，不是热插拔。Console 的 `PUT /control-plane-plugins` 路由因此被标注为“为下一次进程启动配置一个 Control Plane Plugin”——它写下意图，由一次重启来落实。

注册表本身是一个 GenServer，其状态在进程生命周期内不可变。如果模块校验、唯一性不变式或配置注册在 `init/1` 期间失败，它返回 `:stop`，这会在系统能带着一套只注册了一半的 plugin 跑起来之前，中止应用启动。一个坏的 plugin 会让启动明确失败，而不是悄悄失败。

## 运维界面

两条 console 范围的路由覆盖这套模型：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/control-plane-plugins` | 列出已激活与下一次启动的 plugin 状态 |
| `PUT` | `/control-plane-plugins` | 为下一次进程启动配置一个 plugin |

两者都经过 Console 策略（`control_plane_plugins` 的 read 与 update 动作），所以它们和 Console 的其余部分受同一套管理员权限约束。列表响应同时展示当前已激活的，以及已为下一次启动排定的，这样运维者能把两者区分开。

## 与第一方扩展模型的关系

项目的设计规则是把扩展模型当作受信任的、第一方的东西，Control Plane Plugins 正是这个界面。一个 plugin 和它所扩展的代码一起编译进发布；它跑在与控制面相同的信任域里。plugin 和控制面之间没有沙箱，因为 plugin *就是* 通过契约声明了自己的控制面代码。

这就是模型停在该停之处的原因。没有第三方 marketplace、没有热加载、没有按 plugin 的隔离——那些会是不同的产品，带着不同的威胁模型。这个模型提供的，是一种有约束的方式，让第一方代码贡献出控制面已经知道如何消费的能力，在启动时校验，通过运维者的显式选择激活。

## Control Plane Plugins 不是什么

它不是运行时插件商店，也不是运送运维者未曾审阅过的代码的途径。Agent Computer Worker 的工具或 skill 不在这里——那些是 [Agent Library](../agent-library/) 的能力和 worker 侧的工具。它也不可热配置；下一次启动才生效是契约，它之所以存在，是因为一个 plugin 所改动的东西（子进程、配置键）是启动时的事。边界是干净的：第一方代码，通过契约声明，在启动时校验，在下一次启动时激活。

## 下一步

- 一个 plugin 可以声明的 signal adapter，读 [SignalsGateway](../signals-gateway/)。
- 一个 plugin 贡献的 AppConfigure 键，读 [Console](../console-api/)。
- 这套扩展机制使用的信任模型，见 [主体与 AuthZ](../principal-authz/)。
