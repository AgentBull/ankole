---
title: 浏览器自动化
description: Ankole Agent 如何操控真实的浏览器会话：browser Skill 的适用场景、启用方式，以及为什么必须通过预配置的 ankole-browser CLI 而非自行拉起 Chromium。
section: Guides
order: 305
---

借助 `browser` Skill，Agent 能够像真人一样操控真实浏览器：打开网页、点击元素、填写表单、读取前端渲染后的页面状态、截取画面，或针对当前活跃会话运行可复现的 Playwright 脚本。这项能力并非底层固定工具，而是通过 [Agent Library](../agent-library/) 管理的内置 Skill，并固定作为 [后台 Agent 任务](../background-jobs/)执行。本页从运维视角说明它的定位、启用方式，以及 Agent 操作浏览器时必须遵守的边界。

先明确最关键的一条准则：**每个浏览器会话只有一个合法的托管方，那就是运行时（Runtime），而不是 Agent 自身。**Agent 只能通过 Worker 镜像预配置的 `ankole-browser` CLI 操控浏览器，严禁自行拉起 Chromium 进程，也严禁私下调用 `chromium.connectOverCDP`——一旦绕开 CLI 另起炉灶，就会产生第二个失控的控制端，彻底破坏运行时的会话恢复机制。

## 浏览器自动化是什么

Ankole 的浏览器自动化能力封装在内置的 `browser` Skill 中（源码位于 `app/library/skills/browser/SKILL.md`），默认开启（`default_enabled: true`），且运行位置声明为后台任务（`ankole-runtime: background_job`）。每当 Agent 调用这项能力时，实际操作都会在一个与主对话回合隔离的后台任务中执行，并对接由运行时统一托管的真实 Chromium 会话。

`SKILL.md` 中的描述本身就是指导模型何时启用浏览器的选择准则：只有当任务依赖前端 JavaScript 渲染后的 DOM 状态、页面交互、视觉截图、持久化登录态或可复现的 Playwright 多步流程时，才应动用浏览器；如果只是检索公开信息或提取网页正文，应优先选用轻量的 [web_search](../web-tools/) 或 [web_fetch](../web-tools/)。

## 何时用浏览器

启动真实浏览器属于高开销重路径，只有纯 HTTP 抓取无法胜任时才应启用，典型场景包括：

- **前端动态渲染与交互**：目标数据必须在前端脚本执行完毕后才会出现，或者需要先点击按钮、滚动列表、填写筛选表单才能加载出来。
- **复用持久登录态**：目标站点要求登录态认证，需要复用由运行时托管的已登录浏览器会话，无法靠简单的无状态抓取完成。
- **视觉截图留证**：任务需要产出页面截图，或需要人工直观核验页面的真实视觉呈现。
- **可复现的 Playwright 自动化流程**：同一套跨页面的多步网页操作需要稳定地反复执行。

如果只是想查找某个网页或提取正文文字，请直接使用 `web_search` 或 `web_fetch`——`browser` Skill 的说明中也明确强调了这一点：这两个工具独立于本 Skill 之外，在不涉及前端交互、登录态、截图或浏览器端脚本时应优先采用，不仅响应更快、成本更低，也不会白占宝贵的浏览器会话资源。

## 如何启用

由于 `browser` 是一项标准 Skill，它的开关通过 [Agent Library](../agent-library/) 管控，而非独立的工具开关。其内置默认值为 `default_enabled: true`，因此在未做额外限制的情况下，新建的 Agent 默认即可使用浏览器。管理员可在两层粒度上灵活管控：

1. **租户默认开关**：保持默认启用时，当前租户下的所有 Agent 均可按需调用浏览器。
2. **单 Agent 独立覆盖**：可针对不需要访问网页交互的特定 Agent 单独关闭，也可在租户整体默认关闭的前提下只为少数指定 Agent 单独放行。

这两层开关均通过 Console 的能力库路由配置，详见 [Console API 参考](../console-api/)。每次读取某个 Agent 的 `library-capabilities` 接口时，控制面都会触发一次实时 Skill 同步，确保返回的是与当前文件系统对账后的最新状态，而非陈旧快照。

## 运行时注入了什么

Agent 无需也无权自行拼装浏览器启动参数。每次启动浏览器后台任务前，运行时都会将所需的全部连接上下文注入执行环境，这些底层参数对 Agent 而言是不透明的：

- 指向运行时托管浏览器会话的**不透明路由标识（route）**
- 已就绪的**浏览器会话实例上下文（browser material）**
- 供 CLI 进程通信的**守护进程套接字（daemon socket）**
- 用于落盘保存截图与导出产物的**产物根目录（artifact root）**

Agent 只需调用 `ankole-browser` CLI 即可透明使用上述环境。底层的会话实例化（materializer）、守护进程监管（daemon supervisor）与网页抓取适配均由 `app/agent_computer/src/browser-runtime/index.ts` 中的 `BrowserRuntime` 类统一掌管：运行时负责管好浏览器生命周期，Agent 只管调好 CLI。

## 那条约束：只有一个浏览器所有者

这是 Agent 绝对不能逾越的硬性红线——运行时是浏览器会话唯一的所有者。因此 Agent 必须做到：

- **一切浏览器操作均通过预配置的 `ankole-browser` CLI 完成**，涵盖 `open`、`snapshot`、`click`、`fill`、`screenshot`、`batch`，以及通过 `run` 执行 Playwright 脚本。
- **绝不自行启动独立的 Chromium 进程。**
- **绝不直接调用 `chromium.connectOverCDP`**，也不得私自探测浏览器 Profile 名称、账号凭据、Provider 配置、CDP 调试端口或控制面内部标识。

设计这条铁律的核心原因在于**故障恢复**：运行时统一掌管着守护进程监管器、会话实例化器与断点恢复链路。一旦 Agent 私自拉起 Chromium 或绕道直连 CDP 端口，就会在受管链路之外造出第二个隐形控制端；当运行时需要做快照检查点、重连恢复或优雅销毁会话时，既感知不到也管不住这条旁路连接，最终会导致浏览器会话陷入状态撕裂。因此，预配置的 `ankole-browser` CLI 是唯一受保护的受管入口。

## agent 如何驱动浏览器

`ankole-browser` CLI 为 Agent 提供了三种递进的调用方式，可按任务复杂度按需选用：

- **单步 CLI 子命令**：适合探路试探与一两步简单的确定性操作，例如 `open`、`snapshot -i`、`click @e2`、`fill @e4 "value"`、`screenshot`。
- **`batch` 批量命令**：适合步骤明确的一连串短操作，支持直接传入引号包裹的多条命令，或从标准输入（stdin）传入二维参数数组（argv 列表），底层复用与单步命令完全一致的参数解析器。
- **`run` 脚本模式**：用于执行 ESM 格式的 JavaScript 脚本，适合包含循环遍历、条件分支、批量结构化抽取、弹窗/文件下载/网络响应拦截协同、精细等待条件或需在内存中跨步暂存变量的复杂场景。`run` 会将原生 Playwright 页面对象直接挂载到单步 CLI 所操控的**同一个物理浏览器会话**上，使脚本逻辑与 CLI 命令无缝共享同一页面上下文。

最后这一点尤为关键：`ankole-browser run` 绝不会另开第二个浏览器，而是直接复用运行时托管的现有会话，因此即便编写复杂的 Playwright 脚本，依然严格满足“单一所有者”契约。

## 运维不该碰的东西

浏览器相关的底层环境变量（包括 `ANKOLE_BROWSER_CHROMIUM_EXECUTABLE`、`ANKOLE_BROWSER_DAEMON_SOCKET`、`ANKOLE_BROWSER_DAEMON_ENTRY` 与 `ANKOLE_BROWSER_RUNNER`）均由 Worker 镜像在构建与启动时固定注入，不属于运维可调参数，且系统禁止在 Console 的“环境变量”页面中覆盖这些同名键。如果业务上确实需要调整浏览器的操作策略或行为准则，请通过定制 Skill 指令来实现。

## 下一步

- 了解支撑 `browser` Skill 的能力库与继承覆盖机制，请参阅 [Agent Library](../agent-library/)。
- 了解无需启动浏览器的轻量级网页搜索与正文抓取工具，请参阅 [Web 工具](../web-tools/)。
- 了解承载浏览器自动化的后台任务运行机制，请参阅 [后台 Agent 任务](../background-jobs/)。
