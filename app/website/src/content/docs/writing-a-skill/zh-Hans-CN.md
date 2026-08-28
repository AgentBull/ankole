---
title: 开发 Skill 与 Control Plane Plugin
description: 为 Agent 增加工作方法，或为控制面增加身份源、聊天适配器、配置项和后台服务。
section: Developer guide
order: 113
---

Skill 和 Control Plane Plugin 都能扩展 Ankole，但它们解决的问题不同。先选对扩展点，再开始写代码。

| 需要增加什么 | 选择 |
|---|---|
| 教 Agent 怎样完成某类工作 | Skill |
| 给 Agent 提供 MCP-backed 工作流及其使用方法 | Skill |
| 增加身份源、聊天适配器或 Provider 类型 | Control Plane Plugin |
| 增加控制面配置项或受监督后台进程 | Control Plane Plugin |

Skill 是 Agent 读取的文件，不需要重新编译控制面。Control Plane Plugin 是编译进控制面的第一方 Elixir 模块，需要注册，并在控制面下次启动时激活。

## 编写 Skill

一个 Skill 是包含 `SKILL.md` 的目录，也可以带参考资料、模板和 `agents/openai.yaml`：

```text
my-skill/
├── SKILL.md
├── agents/
│   └── openai.yaml
├── reference.md
└── templates/
```

目录名使用小写字母、数字、连字符或下划线。内置 Skill 放在 `app/library/skills/`，安装到某个 Agent 的 Skill 则保存在该 Agent 的文件空间。

### 写 frontmatter

`SKILL.md` 顶部的 YAML 用于发现和启用：

```yaml
---
name: my-skill
description: "当 Agent 需要核对供应商合同时使用。"
default_enabled: true
category: productivity
tags: [Contracts]
ankole-runtime: background_job
platforms: [linux]
---
```

`description` 要说明具体触发条件，因为 Agent 会根据它决定是否读取 Skill。需要后台任务隔离时设置 `ankole-runtime: background_job`；只有依赖 Linux 工具时才设置 `platforms: [linux]`。

### 让 Brain 发现随产品发布的 Skill

如果某个 SOP 或方法论不应出现在每个 Prompt 中，但需要在当前工作与其语义相关时被发现，可以使用 `brain-recall-only`：

```yaml
---
name: idea-lineage
description: 追溯一个想法在记忆中的演变——首次提出、最佳表述、立场反转与当前版本，每项都引用已存证据。
tags:
  - 想法演变
  - 思想脉络
brain-recall-only: true
---
```

这个字段只支持随产品发布的独立 Skill 和 Agent Plugin 内的 Skill；安装到 Agent 的 Skill 不使用这种发现模式。随产品发布的 Skill 名称仍然全局唯一，Agent Plugin 成员关系不会增加命名空间。Brain 根据标准 Skill 元数据自动派生 `lazyload-agent-skills/<name>` 发现记录。

不要在 Skill 中加入 `slug`、`type`、`title` 或 `aliases` 等 Object 字段。Brain 搜索 `name`、`description` 和 `tags`，并用名称和标签做自然语言解析。Skill 正文、其他所有 Skill 文件和 Agent 专属教训不会进入 Brain；发现后仍只能通过 `skill_view` 读取。

### 写正文

正文要让一个有能力但不了解项目约定的 Agent 完成任务。至少写清：

1. 什么时候使用。
2. 要读取哪些输入。
3. 按什么顺序工作。
4. 结果必须包含什么。
5. 哪些动作禁止或需要确认。

参考资料和模板应从 `SKILL.md` 中按名称链接。Agent 只会按需读取这些文件，所以不能假设它会自动发现未被引用的资料。

### 声明 MCP 依赖

需要 MCP 能力时，在 `agents/openai.yaml` 中声明执行依赖：

```yaml
dependencies:
  tools:
    - type: mcp
      value: my-mcp-server
      transport: streamable_http
      url: https://mcp.example.com/mcp
      bearer_token_env_var: MY_MCP_TOKEN
```

只有启用该 Skill 时，这个依赖才可用；它不会注册成模型原生工具。在 `SKILL.md` 中写明领域工具和选择规则，只用 `mcporter list server.tool --schema --json` 检查已选工具，并用 stdin JSON 调用。完整合同见 [MCP 参考](../mcp/)。

### 验证 Skill

在测试 Agent 上启用 Skill，给出一个真实任务，并检查 Agent 是否正确选中 Skill、读取所需资料并遵守完成标准。若 Agent 从未选中它，先改 `description`；若执行步骤不稳定，改正文中的顺序和约束。

对于 `brain-recall-only` Skill，还要确认普通 Prompt 不会列出它，Brain 可以根据名称、描述和标签找到它。确认 `skill_view` 会在兼容的执行位置加载完整 Skill，并在不兼容的执行位置保留既有的路由或拒绝行为。然后关闭该 Skill 或它所属的 Agent Plugin，确认同一个 Agent 既不能发现它，也不能加载它。

## 开发 Control Plane Plugin

Control Plane Plugin 适合扩展控制面拥有的能力。模块实现 `Ankole.Plugins.Plugin`，最小实现只有一个稳定的 Plugin ID：

```elixir
defmodule Ankole.Plugins.MyPlugin do
  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "my-plugin"
end
```

Plugin ID 使用小写 slug。其他回调按需要实现：

| 回调 | 用途 |
|---|---|
| `display_name/0`、`description/0` | Console 中显示的名称与说明 |
| `adapter_declarations/0` | 声明身份源、聊天渠道或其他适配器 |
| `app_config_definitions/0` | 声明固定的 AppConfigure 配置项 |
| `app_config_patterns/0` | 声明带动态 ID 的配置项 |
| `children/0` | 启动长连接、Registry 或定期调和进程 |

### 注册 Plugin

把模块加入 `config/config.exs`：

```elixir
config :ankole, :control_plane_plugin_modules, [
  Ankole.Plugins.MyPlugin
]
```

注册后，Plugin 会出现在 Console 的目录中。管理员启用它后，控制面会在下一次启动时注册配置项、适配器和受监督进程。Plugin 不支持热加载。

### 声明适配器

`adapter_declarations/0` 返回适配器声明。`contract_id` 决定由哪个子系统读取：

```elixir
@impl true
def adapter_declarations do
  [
    %{
      contract_id: "signals_gateway.adapter",
      id: "my-adapter",
      plugin_id: plugin_id()
    }
  ]
end
```

适配器的专属字段由对应子系统定义。聊天适配器应遵循 [SignalsGateway](../signals-gateway/) 的契约；身份源和模型 Provider 也应使用各自现有的注册表，不要在 Plugin 内另建平行配置。

### 声明配置与后台进程

运维人员需要在运行期管理的设置应通过 `app_config_definitions/0` 或 `app_config_patterns/0` 声明。只有数据库可用前必须存在的启动参数才使用环境变量。

`children/0` 返回标准 OTP child spec。长连接和调和进程必须进入 Plugin 的监督树，随 Plugin 激活而启动，并在停用后的下次控制面启动时停止。

### 验证 Plugin

先运行控制面测试和静态检查，再从 Console 启用 Plugin 并重启控制面。确认它显示为已激活，配置项可见，声明的适配器能完成一次真实连接。若它包含外部协议，还要运行对应的集成测试。

## 继续阅读

- Skill 的启用、继承和安装方式见 [Agent 能力库](../skills/)。
- Plugin 的发现与激活边界见 [Control Plane Plugins](../control-plane-plugins/)。
- 新增 LLM Provider 见 [添加 Provider](../adding-a-provider/)。
