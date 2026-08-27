---
title: Agent
description: 在 Console 中创建 Agent，设置负责人、长期行为、模型、能力和环境变量。
section: User guide
order: 13
---

Agent 是一位长期工作的数字同事。每个 Agent 都有自己的身份、负责人、工作要求、模型、能力和文件空间，并通过信号路由规则接收来自聊天渠道的消息。

## 创建 Agent

1. 打开 **Console → 智能体**，选择“新增智能体”。
2. 填写必填的显示名称。Console 会自动生成 UID，例如 `Research Analyst` 会生成 `research-analyst`，“研究分析师”会生成 `yan-jiu-fen-xi-shi`；中英文混合名称也支持。
3. 检查或修改 UID，再填写角色和可选的头像 URL。UID 是实例内唯一的稳定标识，保存后不能修改；显示名称可以随时修改，不会影响已有配置。
4. 选择负责该 Agent 的人类 Principal，再选择群聊记忆披露模式。
5. 保存。页面随后会显示该 Agent 的长期设定、模型档案和专用环境变量。

角色用于概括 Agent 承担的工作，例如“研究分析师”或“客户支持”。职责、行为、视觉设计和保密要求分别由下面四份长期文档管理。

## 设置负责人和群聊披露模式

每个 Agent 都必须有负责人。负责人可以查看该 Agent 编写或持有的知识，以及受众为该 Agent 的知识。若负责人不是某个 Group 的成员，负责人不能凭借所有权读取该 Group 的知识。

群聊记忆披露模式控制 Agent 在多人可见的对话中可以说出哪些知识：

- **严格**要求群聊中的每位在场者都满足该条记忆的受众范围。
- **宽松**只检查提问者，其他在场者不会收窄结果。

两种模式在私聊中的行为相同。除非群组明确接受更宽的披露规则，否则使用“严格”。完整的知识与披露模型见 [Brain](../brain/)。

## 设置长期文档

打开 Agent 编辑页中的 **MISSION / SOUL / DESIGN / CONFIDENTIALITY POLICY**：

| 文档 | 应该写什么 |
|---|---|
| `MISSION.md` | Agent 为什么存在、负责哪些工作、什么结果算完成 |
| `SOUL.md` | 沟通方式、判断原则，以及面对不确定情况时如何行动 |
| `DESIGN.md` | Agent 制作网页、幻灯片、文档、图表等视觉内容时使用的设计系统 |
| `ConfidentialityPolicy.md` | Agent 主动向 Brain 写入知识时如何选择受众范围 |

`DESIGN.md` 遵循 <a href="https://www.designmd.co/about" target="_blank" rel="noreferrer">DESIGN.md 格式</a>：YAML frontmatter 保存颜色、字体、间距、圆角和组件等设计 token，Markdown 正文解释视觉原则及其使用方法。Ankole 内置了一份可直接使用的默认设计系统，也可以在 **Console → 智能体 → DESIGN** 中改成企业自己的品牌规范。

不要把工作流程、权限边界或行为要求写进 `DESIGN.md`。这些内容属于 `MISSION.md`、`SOUL.md`、`ConfidentialityPolicy.md` 或具体 Skill。`ConfidentialityPolicy.md` 只指导 Agent 主动写入 Brain；系统从聊天中自动学习时，受众范围由对话参与者决定。长期文档先写得少而明确，再根据真实使用中的问题补充。

保存后的修改会从后续对话开始生效，已经在执行的工作仍使用开始时读取到的版本。

## 配置模型

在同一编辑页的“模型档案”中，至少配置 `primary`、`light` 和 `heavy`。它们分别承担日常对话、轻量任务和复杂推理；第一次设置时可以选择同一个已验证可用的模型。

其他档案按实际需要配置：

- Agent 需要读图片时，配置 `vision_fallback`。
- Agent 需要搜索或读取公开网页时，配置 `web_search` 和 `web_fetch`。
- Agent 需要生成图片时，配置 `image_generate`。
- 后台 Agent 任务需要单独选择 Provider 或模型时，配置“后台 Agent 任务”。ChatGPT 订阅也通过普通的 [ChatGPT 订阅 Provider](../chatgpt-subscription-provider/) 选择。

先选择模型提供商，再选择或输入模型；上下文长度也只有在选择提供商后才可填写。上下文长度留空时，使用提供商和模型的默认值。

高级设置只显示所选提供商声明的选项。“推理摘要”只用于 Responses API；“回答详略”设置默认详细程度；“服务等级”覆盖当前模型档案的请求等级。可用值取决于提供商、账号和模型，留空时均使用提供商默认值。

模型提供商和首次模型配置见 [快速开始](../quickstart/#3-添加模型提供商并创建-agent)。

## 配置能力和环境变量

Agent 会继承实例默认启用的 Agent Plugin 和 Skill。需要调整时，打开 **Console → Agent 能力库**，修改默认设置或为该 Agent 单独覆盖。具体方法见 [Agent 能力库](../skills/)。

若某个 Skill、命令行工具或 MCP 服务需要 API key，可以在 Agent 编辑页的“环境变量”中添加。Agent 专用值只提供给这个 Agent，并会覆盖同名的全局值。具体方法见 [环境变量](../worker-env/)。

## 接入聊天渠道

Agent 创建完成后，还需要一条信号路由规则，才能接收 Slack、Microsoft Teams、飞书 / Lark 或钉钉中的消息。

打开 **Console → 信号路由**，选择聊天应用和目标 Agent。一个聊天应用可以建立多条规则，也可以为不同 Agent 准备不同的机器人应用。具体方法见 [信号路由规则](../signal-bindings/)。

## 修改或停用

显示名称、角色、长期设定、模型和能力都可以随时修改。UID 不能修改，因为其他配置会用它识别这个 Agent。

停用 Agent 后，它不会继续处理新工作。若只是想暂时停止某个聊天入口，停用对应的信号路由规则即可，不必停用整个 Agent。

## Agent 没有回复时

依次检查：

1. Agent 是否处于启用状态。
2. `primary`、`light` 和 `heavy` 是否都已配置，模型提供商是否可用。
3. 是否存在指向该 Agent 的信号路由规则。
4. 是否至少有一个工作节点处于“就绪”状态。
5. 在 **Console → 会话** 中是否出现了这次消息，以及页面显示了什么错误。

聊天渠道特有的问题见 [快速开始的排障部分](../quickstart/#agent-没有回复时)。
