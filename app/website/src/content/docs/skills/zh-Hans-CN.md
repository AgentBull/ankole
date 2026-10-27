---
title: Agent 能力库
description: 统一管理租户与单 Agent 级的 Agent Plugin、Skill，以及站点级的 Control Plane Plugin。
section: User guide
order: 32
---

站点管理控制台中的 **Agent 能力库** 页面集中管理两类职责边界完全正交的扩展组件：一类是作用于租户与单个 Agent 的模型层能力（**Agent Plugin** 与 **Skill**），另一类则是严格限定在**站点级（Site-Scoped）**的底层平台扩展（**Control Plane Plugin**，仅在顶部作用域选为**全局默认值**时显示）。

这三类组件全部是随当前部署镜像构建分发的第一方受信代码。Agent 能力库并非开放的第三方插件市场——在页面上开启任何能力，都不会在运行时从公网拉取未经审计的外部代码。

## 先分清三类能力

| 类型 | 作用域 | 核心用途 | 生效时机 |
|---|---|---|---|
| **Agent Plugin** | 租户默认值 + 单 Agent 覆盖 | 将一组配套的 Skill、MCP 集成与工作区模板打包为完整业务能力 | Agent 的下一轮工作 |
| **Skill** | 租户默认值 + 单 Agent 覆盖 | 向 Agent 传授某类可重复工作的标准作业说明与配套脚本资源 | Agent 的下一轮工作 |
| **Control Plane Plugin** | 仅站点级（`/api/v2/site/control-plane-plugins`） | 编译期装入的全栈平台扩展（含子系统适配器、受监督 OTP 进程、外层 HTTP Plug、扩展路由、领域事务钩子、配置表单与前端强类型 UI 插槽） | 随构建固定启用（`activation: :always`），或控制面下次启动时生效（`activation: :optional`） |

### Agent Plugin：一组可以共同启用的能力

Ankole Agent Plugin 是 <a href="https://developers.openai.com/plugins" target="_blank" rel="noreferrer">OpenAI Plugins</a> 规范的超集。

在标准 OpenAI Plugin 将一个或多个 Skill、MCP Server 及可选交互界面打包在一起的基础上，Ankole 进一步引入了**工作区模板（Workspace Template）**机制。因此，一个 Agent Plugin 远不止一段静态提示词，而是能够一次性配齐方法论指引、外部工具依赖以及执行复杂任务所需的初始文件环境。

在 Console 中启用某个 Agent Plugin，即代表允许目标 Agent 使用该能力包；至于包内附带的各个子 Skill，依然支持按需单独开启或关闭。

#### 工作区模板：为复杂任务准备完整工作环境

工作区模板存放在 Agent Plugin 目录下的 `workspace-template/` 子目录中。每当创建后台 Agent 任务（Job）时，Ankole 都可以将该模板完整克隆到新任务的专属工作区目录内。

模板中可预先放入定制的 `AGENTS.md`、标准目录层级、调研方法论、自动化校验脚本、Playbook 手册及其他支撑文件。这样一来，后台任务拿到的是一个可随时读写落盘、故障后也可无缝断点恢复的结构化工程目录，而非每轮对话临时拼接的零散提示词。

业界领先水平的 [Deep Research](../deep-research-job/) 便是这一机制的典型代表：先由主对话 Agent 与用户澄清研究目标，随后拉起初始化了 `deep-research` 工作区模板的后台任务。模板已提前备妥研究阶段划分、原始证据归档目录、交叉分析框架与引文核验脚本，使后台任务能够在同一工作区内持续搜集信源、迭代推演并最终成稿。

注意，开启包含工作区模板的 Agent Plugin 并不会改动既有会话，也不会自动拉起后台任务；只有当新创建的任务明确选用该模板时，系统才会用它初始化对应的任务工作区。

### Skill：一种可重复的工作方法

Ankole Skill 完全兼容 <a href="https://agentskills.io/specification" target="_blank" rel="noreferrer">Agent Skills 官方规范</a>。

每个 Skill 至少包含一份带 YAML Frontmatter 的 `SKILL.md` 主文档，也可按需附带 `scripts/`、`references/` 与 `assets/` 子目录。为节省上下文窗口，Agent 最初仅在目录中看到各 Skill 的名称与简介；只有判断当前任务确需某项技能时，才会按需展开读取全文与配套资源。

Skill 最适合用来沉淀“某类具体业务应当按什么步骤推进”。当作业流程中需要拉取外部实时数据、携带身份凭证调用接口或执行受控变更时，Skill 可直接指定调用挂载在其背后的特定 MCP 领域工具并经由 `mcporter` 执行，从而避免将庞大的原始 MCP 工具目录直接摊开成第二套干扰模型的全局工具表。

#### Ankole 扩展：选择 Skill 的执行位置

Ankole 在标准 Frontmatter 之上扩展了 `ankole-runtime` 字段，用于限定该 Skill 可在何处加载：

```yaml
---
name: my-skill
description: 在符合条件的任务中使用。
ankole-runtime: any
---
```

| 取值 | 可用环境 | 适用场景 |
|---|---|---|
| `any` | 主对话 Agent 与后台 Agent 任务 | 两种执行环境均可安全完成的通用操作（省略该字段时的默认值） |
| `main` | 仅限主对话 Agent 的日常交互 | 需要直接向用户追问澄清、确认方案选项，或负责创建与调度后台任务 |
| `background_job` | 仅限后台 Agent 任务 | 耗时长、强依赖任务专属工作区，或需集中运行文件处理、网页浏览与数据分析 |

该字段仅控制对应 Skill 出现在哪一类执行环境的目录中，本身不会触发后台任务创建。例如，Deep Research 的入口协调 Skill 标记为 `main`，专门负责在聊天窗口中与用户敲定调研范围并派发任务；而真正承担长耗时文献检索与交叉验证的子 Skill，则在后台任务环境中加载运行。

#### Ankole 扩展：通过 Brain 发现 Skill

部分专业 SOP 与细分方法论只有在遇到特定类型的课题时才派得上用场，若常驻在每次请求的默认目录里反而白白消耗上下文。为此，随系统发布的内置 Skill 可在头部声明 `brain-recall-only: true`：它依然是标准 Skill，继续遵循原有的父级 Agent Plugin 开关、单 Skill 启用状态、`ankole-runtime` 执行位置限制及 `skill_view` 加载契约，区别仅在于平时不列入模型直接可见的默认 Skill 目录，改由 Brain 通过语义检索按需召回。

运行时，Brain 会检索各候选 Skill 的名称、描述与标签；一旦命中相关条目，Agent 即可调用 `skill_view` 读取详情——`skill_view` 会严格核查 `ankole-runtime` 约束，在匹配的执行环境中加载正文，或返回明确的环境路由提示与权限拒绝。只要关闭了该 Skill 或其所属的父级 Agent Plugin，当前 Agent 就既无法通过 Brain 检索到它，也无法直接加载它（注：此语义发现路径要求实例已启用 Brain）。这一模式非常适合存放体量较大、按需取用但无需每轮常驻提示词的专业方法论与行业 Playbook。

### Control Plane Plugin：站点级全栈平台扩展

Control Plane Plugin 与 OpenAI Plugin 毫无关系，既不进入任何 Agent 的提示词上下文，也绝不支持按租户或单个 Agent 分别启停。它是在编译期静态打包进系统的站点级（Site-Scoped）全栈平台扩展，在控制面节点启动阶段一次性解析完毕，并固化写入 `:persistent_term` 高速只读快照中。

一个 Control Plane Plugin 可以跨前后端同时注入以下平台级扩展点：

- 子系统驱动适配器（`signals.adapter`、`principals.identity_provider`、`ai_gateway.provider`、`agent_workers.provider`）以及受监督的常驻 OTP 进程（`children/0`）；
- 外层 HTTP 前置 `Plug` 与双作用域扩展 JSON:API 路由；
- 同步领域写事务钩子 `hooks/0`（基于 `Ankole.Plugins.Hook`）；
- 声明式 `AppConfigure` 配置表单字段（`ConfigFields`）与前端强类型 Web UI 替换插槽（`entries.json` 中的 `overrides`）。

每个 Control Plane Plugin 均显式声明 `activation: :optional | :always`：可选插件（默认为 `:optional`）由全局配置项 `plugins.enabled_ids` 控制，变更保存后在控制面下次重启时生效；核心平台插件（`activation: :always`）则随当前发行版固定激活，不提供关闭选项。至于日常需要免重启即时切换、或按特定目标与流量比例灰度放量的运行时特性开关，Ankole 采用独立的 OpenFeature 机制（`Ankole.Features`）承载。

## 管理 Agent Plugin 和 Skill

### 设置实例默认值

1. 打开 Console 的 **Agent 能力库** 页面。
2. 将顶部作用域保持为**全局默认值**。
3. 在 **Agent Plugins** 或 **Skills** 标签页中找到目标能力项。
4. 切换默认启用或关闭状态。

此处设定的默认值决定了后续新建 Agent 以及未单独配置例外覆盖的现有 Agent 是否默认拥有该能力。开关变更不会打断已经在途运行的推理回合，自该 Agent 的下一轮工作起才会加载更新后的能力集合。

日常运维中最省心的做法是：将绝大多数岗位通用的基础能力设为全局默认开启，再针对个别职责受限的 Agent 单独收窄；而对于仅服务于少数专职岗位、依赖高权限外部密钥或伴随明显外发风险的能力，则建议保持全局默认关闭，仅对目标 Agent 定向放开。

### 为单个 Agent 设置例外

1. 在 **Agent 能力库** 页面顶部，将作用域下拉框切换为目标 Agent。
2. 找到需要调整的 Agent Plugin 或 Skill。
3. 将状态设为**跟随全局**、**开启**或**关闭**。

选择**跟随全局**代表清除该 Agent 的独立覆盖值，日后调整全局默认开关时该 Agent 会随之同步变化；显式选定**开启**或**关闭**则会保存为该 Agent 专属的独立策略。

当一个 Agent Plugin 内包含多个子 Skill 时，关闭父级 Plugin 会令其下辖的所有子 Skill 暂时一并停用，但不会覆盖各子 Skill 原本保存的独立开关状态；日后重新开启父级 Plugin 后，各子 Skill 会立即恢复原先各自的启用或关闭设置。

### 复核技能教训

在读取完整 Skill 正文时，Agent 还能一并收到附带日期的简短过程注意事项：既包括后台 Dreaming 从历史任务记录中自动提炼、带有租约有效期的机器教训，也包括运维人员手工录入的人工教训，而底层共享的 `SKILL.md` 文件始终保持原样不被改动。

将 **Agent 能力库** 顶部作用域切换至具体 Agent 并展开对应 Skill 卡片，即可查阅当前生效与已退场的全部教训、关联的证据任务、最近复审日期及退场原因。运维人员可随时手工补充新教训或清退不当条目，清退操作从下一轮工作起立即生效。

请勿将放之四海皆准的通用业务规范逐一重复粘贴到每个 Agent 的专属教训中——对全体 Agent 普遍适用的规则应直接修入 Skill 源文件。关于证据采信门槛、租约复审与系统配置项的详细说明，请参阅 [技能教训](../skill-lessons/)。

## 管理 Control Plane Plugin

### 启用或关闭可选站点插件

由于 Control Plane Plugin 严格属于站点级配置（对应 `/api/v2/site/control-plane-plugins`），该面板仅在登录站点管理控制台（`/site-admin-console`）且顶部作用域处于**全局默认值**时才会展示：

1. 在站点管理控制台中打开 **Agent 能力库**，确认顶部作用域为**全局默认值**，随后切换至 **Control Plane Plugins** 标签页。
2. 找到目标可选插件（`activation: :optional`），将其设为**下次启动开启**（声明为 `activation: :always` 的核心插件随镜像固定启用，无关闭开关）。
3. 保存更改后重启控制面服务。
4. 刷新 **Control Plane Plugins** 标签页，确认插件状态已变为**当前已运行**。
5. 随后前往对应管理页面，配置由该插件注册的聊天渠道、身份源提供商、Worker 算力驱动或系统参数。

Docker Compose 环境重启命令：

```bash
docker compose restart control-plane
```

Kubernetes 环境滚动重启命令：

```bash
kubectl -n ankole rollout restart deployment/ankole-control-plane
```

停用可选 Control Plane Plugin 同样需要等待控制面下次启动才正式生效。在保存停用操作时，配置写事务会强制运行 `veto_disable` 依赖引用检查：例如对于提供 Worker 算力驱动的插件，只要整站任意租户下仍存在绑定了该驱动类型的 Agent Worker（包括处于暂停状态的 Worker 或正在清理删除途中的 Agent），系统都会直接拦截并拒绝停用。因此，停用任何站点插件前，请先确认已清空依赖它的聊天路由、身份源及工作节点。若仅需免重启的动态功能开关，请改用 OpenFeature（`Ankole.Features`）。

## 排查问题

### Agent Plugin 和 Skill

- **在能力库列表中找不到目标项**：检查当前运行的部署镜像版本是否已打包该组件——能力库仅展示随当前实例构建安装的第一方组件。
- **单个 Skill 显示已开启，但 Agent 依然无法调用**：检查其所属的父级 Agent Plugin 是否处于关闭状态，确认开启后发起新一轮对话再试。
- **某项 Skill 只在主对话中可见，或只在后台任务中可用**：核对该 Skill 头部声明的 `ankole-runtime` 字段——设为 `main` 的不会注入后台任务，设为 `background_job` 的也不会出现在日常前台对话中。
- **调整全局默认值后，个别 Agent 并未同步生效**：这些 Agent 大概率配置了单 Agent 独立覆盖值，请将顶部作用域切换至对应 Agent 检查并改回“跟随全局”。
- **创建后台任务时无法选用预期的工作区模板**：确认提供该模板的 Agent Plugin 已对当前 Agent 启用，且该插件包内确实包含 `workspace-template/` 目录。

### Control Plane Plugin

- **页面上看不到 Control Plane Plugins 标签页**：该标签页仅限站点级管理。请确认当前访问的是站点管理控制台（`/site-admin-console`），且已将 **Agent 能力库** 顶部的作用域设为**全局默认值**。
- **插件状态一直停留在“下次启动开启”**：配置虽已落库写入 `plugins.enabled_ids`，但还需重启控制面进程以重新生成启动期插件快照。
- **开关置灰或报错无法关闭**：该插件声明了 `activation: :always` 固定启用，或者某个租户下仍有现存 Agent Worker 引用了它提供的算力驱动，从而触发了 `veto_disable` 保护拦截。
- **启用插件并重启后，控制面进程无法正常拉起**：查阅控制面启动日志，核查该插件依赖的外部环境变量或系统参数是否漏配，修复配置后再次启动。
- **插件已开启，但信号路由页面仍看不到对应聊天渠道**：先回到插件列表确认状态已变为**当前已运行**（而非尚未重启的待生效状态），再核查对应渠道的具体接入配置。

如需自行编写自定义 Skill 或开发控制面扩展插件，请参阅 [开发 Skill 与 Control Plane Plugin](../writing-a-skill/)。
