---
title: Agent 能力库
description: 为全部或单个 Agent 启用 Agent Plugin、Skill 和 Control Plane Plugin。
section: User guide
order: 32
---

Agent 能力库决定 Agent 可以使用哪些工作方法和扩展能力。Console 把它们分成三类：

这些能力都是当前实例中已经安装的受信任组件。Agent 能力库不是公开插件市场；在这里启用一个项目，不会从互联网下载未知代码。

## 先分清三类能力

| 类型 | 作用 | 何时生效 |
|---|---|---|
| **Agent Plugin** | 把相关 Skills、MCP 能力和工作区模板组织成一套能力 | Agent 的下一轮工作 |
| **Skill** | 教 Agent 完成一种可重复工作的说明和配套资源 | Agent 的下一轮工作 |
| **Control Plane Plugin** | 为控制面增加聊天适配器、身份源、配置项或后台服务 | 控制面下次启动 |

### Agent Plugin：一组可以共同启用的能力

Ankole Agent Plugin 是 <a href="https://developers.openai.com/plugins" target="_blank" rel="noreferrer">OpenAI Plugins</a> 的超集。

OpenAI Plugin 可以把一个或多个 Skills、MCP Server 以及可选界面组织成一个包。Ankole 沿用这套结构，并增加了**工作区模板**。

因此，一个 Agent Plugin 不只是一条提示词。它可以同时提供工作方法、执行工具和完成任务所需的初始工作环境。

在 Console 中开启 Agent Plugin，表示允许 Agent 使用这个包。包内的每个 Skill 仍然可以单独开启或关闭。

#### 工作区模板：为复杂任务准备完整工作环境

工作区模板位于 Agent Plugin 的 `workspace-template/` 目录。创建后台 Agent Job 时，Ankole 可以把模板复制到新 Job 的工作区。

模板可以预先提供 `AGENTS.md`、目录结构、研究方法、校验脚本、Playbook 和其他任务文件。Job 得到的是可以持续写入和恢复的工作区，而不是每轮临时拼接的一段提示词。

达到 SOTA 水平的 [Deep Research](../deep-research-job/) 是典型用例。主 Agent 先确认研究任务，再创建使用 `deep-research` 工作区模板的后台 Job。

模板为 Job 准备研究流程、证据目录、分析方法和校验工具。Job 可以在同一个工作区中持续收集资料、修订分析并生成最终报告。

启用带有工作区模板的 Agent Plugin，不会修改已有会话或自动创建 Job。只有任务明确选择该模板时，Ankole 才会用它初始化新的 Job 工作区。

### Skill：一种可重复的工作方法

Ankole Skill 兼容 <a href="https://agentskills.io/specification" target="_blank" rel="noreferrer">Agent Skills 官方规范</a>。

每个 Skill 至少包含一个带 YAML frontmatter 的 `SKILL.md`，也可以包含 `scripts/`、`references/` 和 `assets/`。Agent 先看到名称和描述，任务匹配后才读取完整说明和所需资源。

Skill 适合表达“这类工作应该怎样做”。需要实时数据、身份验证或受控操作时，它可以选择一个 MCP 领域工具，再通过 mcporter 调用；MCP catalog 不会成为第二套模型可见工具注册表。

#### Ankole 扩展：选择 Skill 的执行位置

Ankole 在标准 frontmatter 上增加了 `ankole-runtime`：

```yaml
---
name: my-skill
description: 在符合条件的任务中使用。
ankole-runtime: any
---
```

| 值 | Skill 在哪里可用 | 适合的情况 |
|---|---|---|
| `any` | 主 Agent 和后台 Agent Job | 两种执行环境都能安全完成的通用工作；省略字段时也使用此值 |
| `main` | 只在主 Agent 的正常对话中 | 需要直接询问用户、确认选择或创建和管理后台 Job |
| `background_job` | 只在后台 Agent Job 中 | 耗时较长、依赖 Job 工作区，或需要集中处理文件、浏览器和数据的工作 |

这个字段只控制 Skill 会出现在哪种执行环境中，不会自动创建后台 Job。

Deep Research 的入口 Skill 使用 `main`，因为它要先在原对话中确认需求并创建 Job。真正执行研究的 Skills 可以在后台 Job 中使用。

### Control Plane Plugin：扩展管理平台

Control Plane Plugin 不属于 OpenAI Plugin，也不会进入 Agent 的工作上下文。它扩展的是 Ankole 控制面。

聊天渠道、身份源提供商、系统配置和受监督后台服务都可以由 Control Plane Plugin 提供。它们会改变控制面的启动结构，所以只能在控制面下次启动时启用或关闭。

## 管理 Agent Plugin 和 Skill

### 设置实例默认值

1. 打开 Console 的**Agent 能力库**。
2. 把作用域设为**全局默认值**。
3. 在 **Agent Plugins** 或 **Skills** 标签页中找到目标能力。
4. 开启或关闭默认值。

全局默认值决定新 Agent 和未单独设置的 Agent 是否可以使用该能力。修改后，已经开始的回合不会改变；下一轮才会读取新的能力集合。

先把大多数 Agent 都需要的能力设为默认开启，再按 Agent 收窄，通常最容易维护。只适用于少数岗位、需要特殊凭证或有明显风险的能力，更适合默认关闭后按需开启。

### 为单个 Agent 设置例外

1. 在 Agent 能力库顶部把作用域切换为目标 Agent。
2. 找到 Agent Plugin 或 Skill。
3. 选择**跟随全局**、**开启**或**关闭**。

“跟随全局”表示不保留单独例外。以后修改实例默认值时，该 Agent 会一起变化。明确开启或关闭则会保留为 Agent 自己的覆盖值。

Agent Plugin 可以包含多个 Skill。关闭父 Plugin 会让其中的 Skill 暂时不可用，但不会改写每个 Skill 原有的设置。以后重新开启父 Plugin 时，各 Skill 会恢复自己的有效状态。

### 复核 Skill 经验

Agent 在使用 Skill 时，可以积累只属于自己的长期注意事项，例如某个内部系统的约定或已经验证过的操作细节。这些内容显示为**技能经验**，Agent 会在读取 Skill 时一并看到。

打开 Agent Plugin 详情或知识库中的**技能经验**即可复核。需要人工补充时，先写清适用场景，再写需要注意的事项。

不要把通用规则重复写到每个 Agent 的经验中；通用内容应回到 Skill 来源统一修改。

## 管理 Control Plane Plugin

### 启用或关闭

聊天渠道和身份源等能力由 Control Plane Plugin 提供。设置方法如下：

1. 打开 **Control Plane Plugins** 标签页。
2. 找到需要的 Plugin，并设置为**下次启动开启**。
3. 保存后重启控制面。
4. 回到 Agent 能力库，确认状态变为**当前已运行**。
5. 再去配置该 Plugin 提供的聊天渠道、身份源或系统设置。

Docker Compose：

```bash
docker compose restart control-plane
```

Kubernetes：

```bash
kubectl -n ankole rollout restart deployment/ankole-control-plane
```

关闭 Control Plane Plugin 也要等下次启动才生效。它可能让现有聊天渠道或身份源不可用；关闭前先确认没有正在使用它的配置。

## 排查问题

### Agent Plugin 和 Skill

- **列表中没有目标能力**：确认当前部署包已经包含它。能力库只能显示实例中已经安装的组件。
- **Skill 显示开启，但 Agent 仍无法使用**：检查它所属的 Agent Plugin 是否已关闭，并重新开始一个回合。
- **Skill 只在部分任务中出现**：检查 `ankole-runtime`。`main` 不会进入后台 Job，`background_job` 也不会出现在主 Agent 的正常对话中。
- **修改全局默认值后只有部分 Agent 不一致**：这些 Agent 可能保留了单独覆盖值；切到对应作用域检查。
- **后台 Job 无法选择工作区模板**：确认提供模板的 Agent Plugin 已为该 Agent 启用，并确认该 Plugin 确实包含 `workspace-template/`。

### Control Plane Plugin

- **Control Plane Plugin 显示下次启动开启**：设置已保存，但控制面还没有重启。
- **重启后控制面无法启动**：查看启动日志，检查 Plugin 需要的配置和依赖；先修正问题，再重新启动。
- **聊天渠道仍未出现**：确认 Plugin 已经是**当前已运行**，再检查该聊天渠道的具体配置。

开发 Skill 或控制面扩展时，读[开发 Skill 与 Control Plane Plugin](../writing-a-skill/)。
