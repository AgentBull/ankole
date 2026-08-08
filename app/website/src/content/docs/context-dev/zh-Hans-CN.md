---
title: Context.dev 网页数据
description: 通过 Context.dev API 让 Agent 读取拒绝抓取的页面、整站抓取、按 schema 抽取结构化数据、查询品牌资料，并按计划监控页面变化。
section: Guides
order: 307
---

Ankole 自带 `web_search` 和 `web_fetch` 读网页，`browser` skill 驱动真实浏览器。还有一类工作三者都盖不住：拒绝普通抓取的页面、要把整个文档站变成干净 Markdown、要网站按你定义的 JSON 结构回应、要连续几个月盯住竞品页面。`context-dev` skill 用 [Context.dev](https://context.dev) 的 API 覆盖这块。

这个 skill 默认关闭，直到你填好 API key 并启用它。每次调用都要花 Context.dev 账户里的 credits，所以开启是一个明确动作。

## Agent 能用它做什么

启用之后，直接说你要的结果，让 Agent 自己选工具：

```text
把 example.com/docs 下的所有页面读一遍，把 API 限制整理成一张表。

这个定价页挡住了我们的抓取，帮我拿到套餐名和月价。

这个邮件签名里的域名，给我它的 logo、品牌色和 LinkedIn 主页。

每天两次盯着 example.com/pricing，套餐价格变了就告诉我。

stripe.com 对应哪个 NAICS 行业代码？
```

能力面分五类：

- **读实时网页。** 搜索、单页转 Markdown 或 HTML、列出一个页面上的全部图片、拿一个域名的 URL 清单。反爬绕过和代理升级是自动的，所以普通抓取被拒的页面通常能读到。
- **整站采集。** 同步抓取最多 500 页，或者提交最多 25000 个 URL 的异步批量任务，适合等不起的规模。
- **按 schema 抽取。** 你给一个 JSON Schema，拿回同样形状的数据，而不是一堆还要再读一遍的正文。
- **品牌与设计。** 从域名、公司名、办公邮箱、股票代码、银行卡流水描述或某一个页面 URL 拿到公司资料：logo、品牌色、社交账号、行业、地址、上市信息。还能拿网站的设计系统、字体、整页截图，以及 NAICS 或 SIC 行业代码。
- **变化监控。** 按间隔重复检查一个页面、一个 sitemap 或一次结构化抽取，记录变化内容，可选 webhook 推送。

## 怎么开启

### 1. 拿 API key

在 [context.dev](https://context.dev) 注册并创建 API key，key 以 `ctxt_secret_` 开头。免费额度是 500 credits，够你确认配置正确并试几个任务。

### 2. 把 key 存成环境变量

打开 **Console → 环境变量**，新建变量：

- **名称：** `CONTEXT_DEV_API_KEY`
- **值：** 你的 `ctxt_secret_...` key
- **加密存储：** 开启

名称必须完全一致，因为 skill 声明的就是这个名字，不认别的。可以给全部 Agent 设置，也可以在 **Console → 智能体 → 选中 Agent → 环境变量** 里只给一个 Agent 设置——只让它花这笔 credits。作用范围规则见 [环境变量](../worker-env/)。

### 3. 启用 skill

打开 **Console → Agent 能力库**，找到 `context-dev` 并启用：可以实例级开启，也可以只对需要的 Agent 开启。默认值加按 Agent 覆盖的模型见 [Agent 能力库](../skills/)。

从 Agent 的下一个回合开始生效。关闭它之后，下一个回合、下一次 Background Agent Job execution 和下一次 Automation Job attempt 都不再带这个连接。

### 4. 确认可用

找一个已启用的 Agent 做件小事，比如查一个你熟悉的域名的品牌资料。如果回复里出现 `401`，说明 key 缺失或不对：确认变量名就是 `CONTEXT_DEV_API_KEY`、它没有显示为“未设置”、并且没有 Agent 专用值覆盖了全局值。

## Ankole 怎么连接

Context.dev 提供的 MCP server 地址是 `https://mcp.context.dev/mcp`。`context-dev` skill 把它声明为 [Skill-backed MCP 依赖](../mcp/)，所以连接只在一次已启用的执行期间存在。Ankole 为每个回合、每次 Background Agent Job execution 或 Automation attempt 单独写一份私有的 mcporter 配置，文件里只写变量名。key 的值留在执行环境中，不会进入配置文件。

Context 官方的桌面端接入方式是浏览器 OAuth 登录，无人值守的 Worker 做不到。Ankole 走的是同一个 server 支持的 API key 路径，通过 `Authorization` 头认证，不需要交互式登录。

这个 server 不会注册成模型原生工具。Agent 读 skill、选定一个工具，再通过 mcporter 调用它。这条路径见 [使用 MCP-backed Skill](../using-mcp/)。

## Credits 与成本

Context.dev 按 credits 计费，价格随工具不同：

| 工作 | Credits |
| --- | --- |
| 单页转 Markdown 或 HTML、一次 sitemap、一次图片清单、解析一个文件 | 1 |
| 网页搜索 | 每条结果 1，最少一次 10 条 |
| 整站抓取 | 每页 1 |
| 截图、字体清单 | 5 |
| 品牌资料、设计系统、结构化抽取、NAICS、SIC | 10 |

控制账单靠两个习惯。第一，抓取和搜索按条计费，所以在大站上不设上限的抓取是最贵的错误；skill 里已经要求 Agent 把页数预算设成它真正会读的数量。第二，监控器只要还在，每次运行都在花钱——每小时一次是每天一次的 24 倍，而且不会自己停，只有删掉才停。Agent 创建监控器时让它把 monitor ID 报给你；如果你只想让一个 Agent 有花钱的能力，就把环境变量的作用范围收窄到那个 Agent。

## 限制

- **credits 是真金白银。** 已启用的 Agent 在开放网页上做任何调研都可能用到这个 skill。介意的话，把环境变量只发给指定 Agent。
- **监控器和批量任务活得比会话久。** 它们存在你的 Context.dev 账户里，不在 Ankole 里。Ankole 没有列出它们的页面，只能让 Agent 通过 skill 去列。
- **返回结果是不可信输入。** 抓回来的页面是网页内容，不是指令。Ankole 按这个前提处理它，你转发时也应该这样看。
- **工作区里的文件不需要这个 skill。** 已经在 Agent 工作区里的 PDF 或图片，用 [`pdf` 和 `ocr` skill](../ocr/) 在本地读，不花钱。

## 下一步

- 仍然是首选的普通搜索与正文读取：[Web 工具](../web-tools/)。
- 需要渲染会话、登录和点击时：[浏览器自动化](../browser-automation/)。
- 这个 skill 背后的声明契约：[MCP server 参考](../mcp/)。
