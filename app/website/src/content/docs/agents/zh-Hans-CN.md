---
title: Agent
description: 说明如何在 Console 中创建 Agent，并设置负责人、长期设定、模型、能力和环境变量。
section: User guide
order: 13
---

Agent 是 Ankole Agent Harness 中可持续执行工作的主体。每个 Agent 都有自己的使命、负责人、权限、工具、模型档案和文件空间。

Agent 可以使用公司大脑中获准访问的知识。信号路由规则将消息和其他事件发送给对应的 Agent。

## 创建 Agent

1. 打开 **Console → 智能体**，选择「新增智能体」。
2. 输入必填的显示名称。Console 会自动生成 UID。例如，`Research Analyst` 会生成 `research-analyst`，「研究分析师」会生成 `yan-jiu-fen-xi-shi`。Console 也支持中英文混合名称。
3. 检查 UID，必要时进行修改。UID 是实例内唯一的稳定标识，保存 Agent 后不能修改。以后可以修改显示名称，不会影响已有配置。
4. 输入角色和可选的头像 URL。
5. 选择一名人员 Principal 作为 Agent 负责人，再选择群聊记忆披露模式。
6. 保存 Agent。页面随后显示长期设定、模型档案和 Agent 专用环境变量。

角色用于概括 Agent 承担的工作，例如「研究分析师」或「客户支持」。以下四份长期文档分别管理职责、行为、视觉设计和保密要求。

## 设置负责人和群聊披露模式

每个 Agent 都必须有负责人。负责人可以查看 Agent 编写、持有或以该 Agent 为可见对象的知识。负责人不属于某个权限组（Group）时，负责人权限不能绕过该权限组的访问限制。

群聊记忆披露模式控制 Agent 在多人可见的对话中可以披露哪些知识：

- **严格**：群聊中的每位参与者都必须位于该条记忆的可见范围内。
- **宽松**：系统只检查提问者。其他参与者不影响可见知识范围。

两种模式在私聊中的行为相同。只有群组明确接受较宽的披露规则时，才选择「宽松」；其他情况选择「严格」。完整的知识与披露模型见 [Brain](../brain/)。

## 设置长期文档

打开 Agent 编辑页中的 **MISSION / SOUL / DESIGN / CONFIDENTIALITY POLICY**：

| 文档 | 填写内容 |
|---|---|
| `MISSION.md` | Agent 为什么存在、负责哪些工作、什么结果算完成 |
| `SOUL.md` | 沟通方式、判断原则，以及面对不确定情况时如何行动 |
| `DESIGN.md` | Agent 制作网页、幻灯片、文档、图表等视觉内容时使用的设计系统 |
| `ConfidentialityPolicy.md` | Agent 主动向 Brain 写入知识时如何选择受众范围 |

`DESIGN.md` 遵循 <a href="https://www.designmd.co/about" target="_blank" rel="noreferrer">DESIGN.md 格式</a>。YAML frontmatter 保存颜色、字体、间距、圆角和组件等设计令牌，Markdown 正文说明视觉原则及其使用方法。Ankole 内置默认设计系统，也可以在 **Console → 智能体 → DESIGN** 中改为企业品牌规范。

不要将工作流程、权限边界或行为要求写入 `DESIGN.md`。这些内容属于 `MISSION.md`、`SOUL.md`、`ConfidentialityPolicy.md` 或具体 Skill。`ConfidentialityPolicy.md` 只指导 Agent 主动写入 Brain。系统从聊天中自动学习时，可见范围由对话参与者决定。首次配置时，长期文档应简短、明确。实际工作发现新问题后，再补充对应规则。

修改保存后，从后续对话开始生效。正在执行的工作继续使用启动时读取的版本。

## 配置模型

在同一编辑页的「模型档案」中，至少配置 `primary`、`light` 和 `heavy`。这三个档案分别用于日常对话、轻量任务和复杂推理。初次配置时，可以为三个档案选择同一个已验证模型。

其他档案按实际需要配置：

- Agent 需要读图片时，配置 `vision_fallback`。
- Agent 需要搜索或读取公开网页时，配置 `web_search` 和 `web_fetch`。
- Agent 需要生成图片时，配置 `image_generate`。
- 后台 Agent 任务需要使用单独的模型提供商或模型时，配置「后台 Agent 任务」。ChatGPT 订阅也通过 [ChatGPT 订阅 Provider](../chatgpt-subscription-provider/) 选择。

先选择模型提供商，再选择或输入模型。选择提供商后，系统会显示上下文长度字段。上下文长度留空时，系统使用提供商和模型的默认值。

高级设置只显示所选提供商声明的选项。「推理摘要」只用于 Responses API。「回答详略」设置默认详细程度。「服务等级」覆盖当前模型档案的请求等级。可用值取决于提供商、账号和模型。字段留空时，系统使用提供商默认值。

模型提供商和首次模型配置见 [快速开始](../quickstart/#3-添加模型提供商并创建-agent)。

## 配置能力和环境变量

Agent 会继承实例默认启用的 Agent Plugin 和 Skill。需要调整时，打开 **Console → Agent 能力库**，修改默认设置或为该 Agent 单独覆盖。具体方法见 [Agent 能力库](../skills/)。

如果 Skill、命令行工具或 MCP 服务需要 API 密钥，在 Agent 编辑页的「环境变量」中添加。Agent 专用值仅对当前 Agent 可用，并覆盖同名全局值。具体方法见 [环境变量](../worker-env/)。

## 接入聊天渠道

创建 Agent 后，配置信号路由规则，使 Agent 可以接收 Slack、Microsoft Teams、飞书（Lark）或钉钉中的消息。

打开 **Console → 信号路由**，选择聊天应用和目标 Agent。一个聊天应用可以建立多条规则，也可以为不同 Agent 创建不同的机器人应用。具体方法见 [信号路由规则](../signal-bindings/)。

## 修改或停用

显示名称、角色、长期设定、模型和能力都可以随时修改。UID 是其他配置识别 Agent 的稳定标识，因此不能修改。

停用 Agent 会停止接收新工作，并在智能体列表中显示「已停用」状态。已停用的 Agent 可以重新启用。只有已停用的 Agent 可以永久删除，永久删除会同时删除对应的会话、任务和记录。如只需暂停某个聊天入口，停用对应的信号路由规则。

## Agent 没有回复时

依次检查：

1. Agent 是否处于启用状态。
2. `primary`、`light` 和 `heavy` 是否都已配置，模型提供商是否可用。
3. 是否存在指向该 Agent 的信号路由规则。
4. 是否至少有一个 Agent Computer Worker 处于「就绪」状态。
5. **Console → 会话** 中是否出现此次消息。
6. 页面是否显示错误信息。

聊天渠道特有的问题见 [快速开始的故障排查部分](../quickstart/#agent-没有回复时)。
