---
title: Web 研究
description: 如何设置一个研究 web 的 agent——web_search 和 web_fetch 工具、model profile、完整多来源研究示例。
section: Guides
order: 326
---

Web 研究是最常见的 agent 工作之一——搜索当前信息、抓取来源、综合发现。Ankole 的 web 工具（`web_search` 和 `web_fetch`）使之可能，model profile 控制哪个 provider 服务它。本指南是一个 web 研究 agent 的实际形态，从设置到完整多来源示例。

先把决定性的性质说清楚：web 研究走 **AIGateway 的 web 工具，不走浏览器**。`web_search` 找来源；`web_fetch` 读它们。browser skill 用于交互工作（登录、截图、渲染页）；研究用于发现和文本提取。用对工具。

## 需要什么

- **绑定 `web_search` profile**——到一个提供 web 搜索的 provider（Jina Search、Bright Data SERP、Parallel 或 Agent Bull Cloud）。没它 agent 不能搜。
- **绑定 `web_fetch` profile**——到一个提供 web 抓取的 provider（Jina Reader）。没它 agent 不能读抓取页的内容。
- **`primary` model profile**——用于综合步骤，agent 读它找到的东西并写摘要。

如何绑定见 [Provider 与模型](../providers-and-models/)。

## 两个工具

| 工具 | 做什么 | 何时用 |
|---|---|---|
| `web_search` | 按查询搜索 web，返回带标题、URL 和摘要的结果 | 发现——"X 方面有什么" |
| `web_fetch` | 抓取一到五个公共 HTTPS URL，返回其文本内容 | 阅读——"读这个来源说了什么" |

agent 调 `web_search` 找来源，然后调 `web_fetch` 读最相关的。简单问题一次搜索一次抓取够了；深入则需要多轮搜索-抓取-综合。

## 何时改用浏览器

用 browser skill（见[浏览器自动化](../browser-automation/)）当：

- 来源需要登录或交互才能到达内容
- 需要截图或渲染页状态
- 内容在 `web_fetch` 无法解析的 JavaScript 渲染后面

普通发现和文本提取，`web_search` 和 `web_fetch` 更快更便宜。

## 一个完整示例

设置一个监控竞品的研究 agent：

1. 绑 `web_search`（到 Jina Search）和 `web_fetch`（到 Jina Reader）。
2. 创建 agent，撰写 `MISSION.md`："跟踪 Acme 公司的产品变化。每周搜他们的博客和 changelog。总结变化附链接。"
3. 加一条[调度](../cron-schedules-ops/)每周触发。
4. 每次触发，agent 搜索、抓取前几条结果、综合摘要、发到绑定的频道。

## 本指南不是什么

它不是 web 爬虫教程——`web_fetch` 读公共 HTTPS 页；它不绕过鉴权或限速。它不是浏览器指南——交互工作读[浏览器自动化](../browser-automation/)。它也不是搜索引擎参考——搜索结果取决于你绑的 provider。

## 下一步

- web 工具，读 [Web 工具](../web-tools/)。
- 绑定 profile，读 [Provider 与模型](../providers-and-models/)。
- 浏览器替代方案，读[浏览器自动化](../browser-automation/)。
- 调度研究，读 [Cron 调度](../cron-schedules-ops/)。
