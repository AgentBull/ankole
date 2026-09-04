---
title: Web 工具
description: 为 Agent 配置网页搜索和正文读取，并判断何时改用浏览器。
section: User guide
order: 33
---

Agent 可以使用 `web_search` 查找公开网页，再用 `web_fetch` 读取选中的页面。`web_search` 必须配置 Provider；`web_fetch` 会优先使用已配置的 Provider，也可以在未配置 Provider 时使用 Worker 内置的渲染回退。

## 先选择正确的工具

| 能力 | 适合做什么 | 运行位置 |
|---|---|---|
| `web_search` | 根据关键词、时间或来源范围查找公开网页 | 主 Agent 和后台 Agent Job |
| `web_fetch` | 把一个或多个已知公开网址读取为正文 | 主 Agent 和后台 Agent Job |
| [浏览器自动化](../browser-automation/) | 登录、点击、输入、翻页、截图和读取交互后的页面 | **仅后台 Agent Job** |

浏览器自动化由 `browser` Skill 提供，并声明为 `ankole-runtime: background_job`。它不会出现在 `web_search` 或 `web_fetch` 的 Provider 列表中，也不能直接在主 Agent 的普通对话回合中运行。

当任务需要浏览器时，需要让主 Agent 创建或使用后台 Agent Job。后台 Job 不会阻塞当前对话，并会按需把问题、状态或结果送回原对话。

## 配置 Web 工具

### 添加 Provider

1. 打开 **Console → 模型提供商**。
2. 选择支持 `web_search`、`web_fetch` 或两者的 Provider 类型。
3. 填写 API Key 和该 Provider 要求的字段。
4. 保存并确认 Provider 处于启用状态。

同一种 Provider 类型可以建立多个实例。例如，你可以为不同地区或用途建立两个 Bright Data SERP Provider，再让不同 Agent 使用不同实例。

### 分配给 Agent

1. 打开 **Console → 智能体**，选择目标 Agent。
2. 在**模型档案**中找到 `web_search`，选择一个支持网页搜索的 Provider。
3. 找到 `web_fetch`，选择一个支持网页读取的 Provider。
4. 分别保存，然后开始一轮新对话。

这两项模型档案只需要选择 Provider，不需要选择模型或填写上下文长度。Provider 类型声明自己支持哪些能力，所以列表只会显示与当前档案匹配的实例。

如果列表中没有可选项，请先添加对应 Provider。首次添加方法见 [快速开始](../quickstart/#3-添加模型提供商并创建-agent)。

## 当前内置 Provider

以后也可以通过 Control Plane Plugin 添加更多 Provider 类型。以下是 Ankole 当前内置的类型。

### `web_search` Provider

| Provider | 同时支持 `web_fetch` | 主要差异 | 适合的情况 |
|---|---|---|---|
| **Parallel** | 是 | 同一 Provider 同时提供搜索和正文提取；支持搜索目标、多条查询、模式和总字符预算 | 希望用一套凭据完成搜索与阅读，或处理研究型查询 |
| **Bright Data SERP** | 否 | 通过 SERP API 搜索；必须填写 Zone，可指定国家、语言和 Google 域名 | 需要控制搜索地区、语言或本地化结果 |
| **Jina Search** | 否 | 支持地区、位置、语言、页码、缓存和搜索引擎选项 | 需要直接的网页搜索，并希望控制地域、分页或缓存 |
| **AgentBull Cloud** | 否 | 聚合多个搜索来源；支持来源范围、时间范围和跳过缓存 | 需要聚合搜索，或需要明确限制来源和时间 |

Parallel 只需添加一个 Provider 实例，就可以同时分配给 `web_search` 和 `web_fetch`。

Jina Search 与 Jina Reader 是两个不同的 Provider 类型。即使它们使用同一套 Jina 凭据，也要分别添加，再分配给对应档案。

### `web_fetch` Provider

| Provider | 同时支持 `web_search` | 主要差异 | 适合的情况 |
|---|---|---|---|
| **Parallel** | 是 | 使用与 Parallel Search 相同的 Provider 和凭据提取正文 | 已经使用 Parallel 搜索，希望保持一套配置 |
| **Jina Reader** | 否 | 把公开网页转换为 Markdown；支持保留链接、目标选择器、等待选择器、缓存、引擎和 token 上限 | 阅读文章正文，或从页面中提取指定区域 |

`web_fetch` 面向公开 HTTPS 页面。它不负责登录，也不是 PDF、图片、压缩包或音视频下载器。

Worker 内置的渲染回退不是 Provider，因此不会出现在 Console 的 Provider 列表中。它只负责读取渲染后的正文。

渲染回退不能点击、输入、复用登录状态或截图，也不会让主 Agent 获得浏览器自动化能力。

选择器和等待选项可以帮助 Provider 读取延迟出现的正文，但不能代替真实交互。需要登录、点击或填写表单时，仍应使用后台 Agent Job 中的浏览器自动化。

## 让 Agent 使用 Web 工具

不需要输入特殊命令，直接说明目标即可。例如：

> 查找本周发布的三条相关消息，阅读原文后总结差异，并附上来源链接。

Agent 会先搜索，再选择需要阅读的页面。若你已经知道网址，可以直接把网址发给 Agent，并要求它读取和总结。

以下情况应明确要求使用浏览器：

- 页面需要登录；
- 必须点击、输入或翻页后才能看到内容；
- 需要截图或核对页面实际显示效果；
- 网页内容只有在复杂交互后才会出现。

浏览器工作会在后台 Agent Job 中运行。普通搜索、公开网页正文读取和多来源整理不需要浏览器，直接使用 `web_search` 与 `web_fetch` 更快。

## 无法搜索或读取网页

### 搜索或读取失败

依次检查：

1. 当前 Agent 是否已配置任务需要的档案；`web_search` 必须选择 Provider。
2. 若 `web_fetch` 没有 Provider，Worker 是否提供内置渲染回退。
3. 所选 Provider 是否声明了对应能力。
4. Provider 是否处于启用状态，凭据和必填字段是否有效。
5. 修改配置后是否开始了新对话。
6. 目标网址是否为公开 HTTPS 页面，且不需要登录。

### 浏览器没有运行

确认 Agent 已启用 `browser` Skill，并允许创建后台 Agent Job。不要尝试把浏览器配置到 `web_search` 或 `web_fetch` 档案中。

如果任务已在后台 Job 中运行，再检查 Worker 是否可用，以及 Job 是否报告了浏览器会话或访问权限问题。
