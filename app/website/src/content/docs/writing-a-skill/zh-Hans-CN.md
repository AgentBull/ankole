---
title: 开发 Skill 与 Control Plane Plugin
description: 为 Agent 沉淀标准作业方法（Skill），或为站点级控制面扩展驱动适配器、配置表单、领域事务钩子、常驻服务与前端插槽（Control Plane Plugin）。
section: Developer guide
order: 113
---

Skill 与 Control Plane Plugin 都是扩展 Ankole 能力的官方途径，但两者面向的系统层级截然不同。动手编码前，请先对照下表选准扩展机制：

| 扩展需求 | 推荐方案 |
|---|---|
| 教会 Agent 按标准步骤完成某类特定业务工作 | Skill |
| 为 Agent 接入挂载在 Skill 背后的外部 MCP 服务及调用规范 | Skill |
| 新增身份源提供商、聊天渠道适配器、LLM 提供商或 Worker 算力驱动类型 | Control Plane Plugin |
| 新增站点级系统配置项、受监督后台常驻进程、领域写事务钩子、扩展 `/api/v2` 路由或前端强类型 UI 插槽 | Control Plane Plugin |
| 在不重启控制面的前提下于运行期动态切换或灰度放量业务策略 | OpenFeature（`Ankole.Features`） |

简言之，Skill 是供 Agent 在运行时按需读取的说明文档与配套资源包，增改无需重新编译控制面；Control Plane Plugin 则是静态编译进发行包的第一方站点级全栈平台扩展（严格限定在全局站点维度，绝不按租户或单个 Agent 切分作用域）：声明为 `:optional` 的插件由站点管理员（`siteadmin`）开启后在控制面下次启动时挂载生效，声明为 `:always` 的插件则随构建版本固定激活。

## 编写 Skill

一个标准的 Skill 就是一个至少包含 `SKILL.md` 的目录，并可按需附带参考手册、文件模板及声明外部工具依赖的 `agents/openai.yaml`：

```text
my-skill/
├── SKILL.md
├── agents/
│   └── openai.yaml
├── reference.md
└── templates/
```

目录名称仅限使用小写英文字母、数字、连字符（`-`）或下划线（`_`）。随源码构建分发的内置 Skill 存放在仓库的 `app/library/skills/` 目录下，单独安装到某个具体 Agent 名下的自定义 Skill 则保存在该 Agent 专属的云盘文件空间内。

### 写 frontmatter

`SKILL.md` 顶部的 YAML Frontmatter 决定了该 Skill 如何被发现、筛选与加载：

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

由于 Agent 在日常对话中全靠阅读 `description` 来判断当前任务是否需要展开该 Skill，请在 `description` 中写明清晰具体的触发场景。若该项工作耗时较长或强依赖独立任务工作区，请显式指定 `ankole-runtime: background_job`；仅当脚本确需依赖 Linux 专属命令行工具时，再声明 `platforms: [linux]`。

### 让 Brain 发现随产品发布的 Skill

如果某份专业 SOP 或细分方法论不宜每轮都塞进所有 Agent 的默认目录浪费上下文，但又希望在遇到语义高度相关的课题时能被精准召回，可在头部加上 `brain-recall-only: true`：

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

这一按需语义召回模式仅支持随产品构建发布的独立内置 Skill 及 Agent Plugin 内包含的子 Skill，不支持单独上传安装到某个 Agent 文件空间的自定义 Skill。所有随产品发布的 Skill 名称依然保持全局唯一，归入某个 Agent Plugin 并不会为其额外叠加命名空间前缀；系统会根据标准 Skill 元数据在 Brain 中自动派生对应的 `lazyload-agent-skills/<name>` 发现索引记录。

编写时请保持纯粹的标准 Skill Frontmatter，切勿混入 `slug`、`type`、`title` 或 `aliases` 等 Brain 知识页专属字段——Brain 会直接索引 `name`、`description` 与 `tags`，并利用名称和标签完成自然语言检索匹配。注意，Skill 正文、附属参考文件以及单 Agent 专属的技能教训均不会写入 Brain 索引库；检索命中后，Agent 依然只能调用 `skill_view` 工具按权限加载正文。

### 写正文

撰写 `SKILL.md` 正文的目标，是让一个具备通用推理能力、但事先并不了解你们团队内部约定的 Agent 能够稳健交付合格结果。正文中至少应交代清楚以下五要素：

1. **适用时机**：遇到什么特征的请求时应当采用本方法；
2. **输入材料**：动手前需要先读取或核实哪些上下文与数据源；
3. **标准步骤**：严格按怎样的先后顺序推进各项检查与操作；
4. **交付标准**：最终产出的报告或结果中必须包含哪些要素；
5. **红线与确认点**：哪些高风险动作绝对禁止，或必须先向用户请示确认。

同目录下的附属参考文档与模板文件，必须在 `SKILL.md` 正文中按准确文件名显式引用——Agent 只会顺着正文指引按需读取关联文件，切勿假设它会自动遍历整个目录去盲找未被引用的材料。

### 声明 MCP 依赖

当作业流程需要调用外部 MCP 服务时，请在 `agents/openai.yaml` 中声明运行依赖：

```yaml
dependencies:
  tools:
    - type: mcp
      value: my-mcp-server
      transport: streamable_http
      url: https://mcp.example.com/mcp
      bearer_token_env_var: MY_MCP_TOKEN
```

上述 MCP 依赖仅在该 Skill 对当前执行环境处于启用状态时才会注入。请在 `SKILL.md` 正文中明确指定应当选用的目标领域工具及筛选准则，引导 Agent 仅在必要时运行 `mcporter list server.tool --schema --json` 查看单个工具的参数定义，并通过标准输入（stdin）传入 JSON 完成调用。完整的配置与隔离契约见 [MCP 参考](../mcp/)。

### 验证 Skill

先在测试 Agent 上开启新写的 Skill，向其发送一条贴近真实业务的测试指令，观察 Agent 能否准确命中该 Skill、按指引读取配套参考文件并严格落实交付标准：若发现 Agent 根本没有点开该 Skill，请优先优化 Frontmatter 中的 `description` 触发描述；若选中后执行步骤跳脱不稳，则进一步收紧正文中的步骤顺序与边界约束。

对于声明了 `brain-recall-only: true` 的内置 Skill，还需额外验证整套按需发现闭环：确认常规对话提示词的默认目录中未列出该条目，而通过名称、描述或标签语义检索 Brain 时能够顺利召回；确认调用 `skill_view` 时，在匹配的 `ankole-runtime` 环境中能正常加载全文，在不兼容的执行环境中则按契约返回路由提示或拒绝结果；最后关闭该 Skill（或其所属的父级 Agent Plugin），确认同一个 Agent 随即既无法在 Brain 中检索到它，也无法再通过 `skill_view` 加载它。

## 开发 Control Plane Plugin

Control Plane Plugin 专用于扩展归属控制面的站点级平台能力。插件入口模块须实现 `Ankole.Plugins.Plugin` 行为（Behaviour），最简实现只需声明一个全局唯一且稳定的小写连字符标识（Slug）：

```elixir
defmodule Ankole.Plugins.MyPlugin do
  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "my-plugin"
end
```

除必填的 `plugin_id/0` 外，可按实际扩展需求选配实现以下回调：

| 回调函数 | 职责用途 |
|---|---|
| `activation/0` | 返回 `:optional`（默认值，通过 `plugins.enabled_ids` 按需勾选并在下次启动时生效）或 `:always`（随构建版本固定激活，管理后台不提供关闭开关） |
| `display_name/0`、`description/0` | 在站点管理控制台中展示的本地化显示名称与功能简介 |
| `adapter_declarations/0` | 注册身份源提供商、聊天渠道、LLM 提供商、Worker 算力驱动（`agent_workers.provider_kind`）或第三方 Webhook 处理器 |
| `hooks/0` | 注册同步领域写事务钩子列表（形如 `[{hook_point, module}]`，钩子模块须实现 `Ankole.Plugins.Hook`） |
| `app_config_definitions/0` | 声明固定键名的 `AppConfigure` 系统配置项 |
| `app_config_patterns/0` | 声明带动态实例 ID 参数的 `AppConfigure` 配置模式 |
| `children/0` | 在插件专属监督树下挂载长连接客户端、本地 Registry 或周期性后台对账进程 |

作为全栈编译期扩展，插件包还可在核心路由器外层包裹前置 HTTP `Plug`、挂载强类型的 `/api/v2/*` JSON:API 扩展路由，并通过前端构建清单 `entries.json` 中的 `overrides` 字段注入强类型 Web UI 扩展插槽（涵盖 `PodAppSlots`、`ConsoleAppSlots` 与 `AuthAppSlots`）。

### 注册 Plugin

将编写好的插件主模块注册进控制面的 `config/config.exs` 列表中：

```elixir
config :ankole, :control_plane_plugin_modules, [
  Ankole.Plugins.MyPlugin
]
```

完成注册并编译后，该插件便会出现在站点管理控制台（`/site-admin-console` 下将作用域设为**全局默认值**时的插件目录，对应接口 `GET` / `PUT /api/v2/site/control-plane-plugins`）。当 `siteadmin` 启用某个 `:optional` 插件并重启控制面时，系统会在启动引导阶段将其解析固化为不可变的 `:persistent_term` 快照，同步完成配置项、驱动适配器、事务钩子及受监督子进程的挂载注册（日后若要停用，只要任一租户下仍有 Worker 引用该插件提供的算力驱动，`veto_disable` 保护机制就会阻止停用）。而声明为 `:always` 的插件只要编译进发行包便会在启动时无条件激活。注意，Control Plane Plugin 不支持运行期热插拔；凡需免重启即时切换的动态业务开关，请改用 OpenFeature（`Ankole.Features`）。

### 声明适配器

`adapter_declarations/0` 返回一组适配器注册声明，其中 `contract_id` 决定了该声明由哪个核心子系统接管消费：

```elixir
@impl true
def adapter_declarations do
  [
    %{
      contract_id: "signals.adapter",
      id: "my-adapter",
      plugin_id: plugin_id()
    }
  ]
end
```

每种适配器声明所需的扩展字段由目标子系统统一规定：聊天渠道适配器须严格遵循 [Signals](../signals/) 契约；身份源、模型提供商与 Worker 算力驱动同样应直接接入各自子系统现有的统一注册表，切勿在插件内部私自另建平行的配置存储。

### 声明配置、事务钩子与后台进程

凡需交由运维人员在运行期查看或调整的参数，均应通过 `app_config_definitions/0` 或 `app_config_patterns/0` 注册进 `AppConfigure`；操作系统环境变量仅限用于存放数据库尚未连通前就必须读取的底层启动引导参数。

若需对核心领域写操作（包括 `:create_agent`、`:create_invitation`、`:enable_signal_binding`、`:enable_identity_provider`、`:store_file`、`:commit_files`、`:create_pod_page`、`:restore_pod_page`、`:insert_base_records` 与 `:admit_compute`）附加同步准入拦截或商业配额核验，可通过 `hooks/0` 挂载钩子模块：每个钩子实现 `Ankole.Plugins.Hook.before_commit_in_tx/2`，直接在调用方所处的数据库写事务内部同步返回 `:ok` 或 `{:error, reason}`（一旦返回错误元组，整个外层领域事务将立即原子回滚）。

`children/0` 则返回标准的 OTP Child Spec 列表：插件自有的外部长连接客户端与后台定期对账进程都必须纳入该插件自身的监督树下托管，随插件激活一同拉起，并在插件被停用后的下一次控制面启动时不再拉起。

### 验证 Plugin

提交代码前请先跑通控制面单元测试与静态检查。针对 `:optional` 插件，请登录站点管理控制台（`/site-admin-console`）将其开启并重启控制面（`:always` 插件会在启动时直接激活）：逐一核实插件状态已变为运行中、声明的 `AppConfigure` 表单正常渲染、领域写事务钩子按契约准确放行或回滚，且注册的外部适配器能够走通一次真实的端到端连接收发；若对接了外部第三方协议，还须补齐并通过对应的真实协议集成测试。

## 继续阅读

- 了解在管理后台启停、继承与管理能力的日常操作，请参阅 [Agent 能力库](../skills/)。
- 深入了解站点插件的发现快照与激活边界设计，请参阅 [Control Plane Plugins](../control-plane-plugins/)。
- 了解如何编写自定义上游模型提供商模块，请参阅 [添加 Provider](../adding-a-provider/)。
