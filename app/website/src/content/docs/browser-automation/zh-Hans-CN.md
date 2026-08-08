---
title: 浏览器自动化
description: Ankole agent 如何驱动一个真实浏览器会话——browser skill、何时该用它而不是 web_search/web_fetch、如何启用、以及为什么 agent 必须用预配置的 ankole-browser CLI 而不是自己启动 Chromium。
section: Guides
order: 305
---

browser skill 让 agent 做真实浏览器工作——打开页面、点击、输入、读渲染后的状态、截图，以及对一个活动会话跑可复现的 Playwright 脚本。它是一个 [skill](../agent-library/)，不是内置工具，且作为 [后台任务](../background-jobs/) 运行。本页是运维视角：这个 skill 是什么、何时开启、agent 对浏览器能做什么、不能做什么。

先说明最关键的一点：每个 agent 会话只有一个浏览器所有者，就是运行时，不是 agent。agent 通过 worker 镜像注入的预配置 `ankole-browser` CLI 来驱动浏览器。它绝不能自己启动 Chromium，也不能调用 `chromium.connectOverCDP`——这两者会造出第二个所有者，绕过会话恢复。

## 浏览器自动化是什么

Ankole 里的浏览器自动化就是 `browser` 这个 skill，源在 `app/library/skills/browser/SKILL.md`。它是内置 skill（`default_enabled: true`），标注为后台任务运行时（`ankole-runtime: background_job`）。agent 调用它时，工作跑在一个后台任务里，与拥有它的回合隔离，针对一个运行时拥有的真实 Chromium 会话。

skill 自带的 description 是模型判断要不要用它的契约：当工作依赖渲染后的页面状态、交互、截图、持久登录态，或可复现的 Playwright 工作流时用浏览器；普通发现和文本抽取请优先用 [web_search](../web-tools/) 或 [web_fetch](../web-tools/)。

## 何时用浏览器

浏览器是重路径。只有 fetch 不够时才用它。具体地：

- **渲染交互**——页面只有在 JavaScript 跑完、或者你点击、滚动、填字段之后才显示你需要的数据。
- **持久登录态**——你需要运行时已经认证过的会话，而简单的 fetch 无法复现那个登录。
- **截图**——任务需要视觉产物，或者需要人看到页面状态。
- **可复现的 Playwright 工作流**——同一个多步浏览器流程要跑不止一次。

只想找一个页面或读它的文本时，请用 `web_search` 或 `web_fetch`。browser skill 自己也这么说：这两个工具在本 skill 之外；当不需要渲染交互、登录态、截图、浏览器侧代码时，优先用它们。fetch 更便宜、更快，也不占用浏览器会话。

## 如何启用

browser 是 skill，所以你通过 [Agent Library](../agent-library/) 开启它，而不是通过工具开关。因为 `default_enabled` 是 `true`，新建的 agent 默认就有浏览器，除非你收窄它。两层：

1. **实例级默认值**——Skill 默认设置 `default_enabled: true`。保持这个值时，每个 Agent 都可以使用浏览器。
2. **按 agent 覆盖**——为不该有浏览器的 agent 收窄它，或为你之前收窄过的 agent 放开它。

两层都通过 Console 的 library-capability 路由设置，见 [Console API 参考](../console-api/)。读某个 agent 的 `library-capabilities` 会触发一次 skill 同步，所以你看到的是注册表对当前文件系统重对账后的结果，不是过期快照。

## 运行时注入了什么

agent 自己不选浏览器配置。browser 任务启动前，运行时把任务所需的一切都注入进来，这些值对 agent 是不透明的：

- 一条通往运行时拥有的浏览器会话的**不透明 route**
- **最终 browser material**（agent 要驱动的、准备好的会话）
- 一个 CLI 通信用的 **daemon socket**
- 一个存放截图和其他产物的 **artifact root**

agent 通过 `ankole-browser` CLI 来使用这些。`app/agent_computer/src/browser-runtime/index.ts` 里的 `BrowserRuntime` 类拥有 materializer、daemon supervisor 和 web-fetch adapter，所以浏览器会话的生命周期是运行时的职责。agent 的职责是调 CLI。

## 那条约束：只有一个浏览器所有者

这是 agent 不能违反的规则。运行时是浏览器所有者。agent 必须：

- **一切操作都用预配置的 `ankole-browser` CLI**——open、snapshot、click、fill、screenshot、batch，以及跑 Playwright 脚本时用 `run`。
- **不自己启动 Chromium。**
- **不调用 `chromium.connectOverCDP`**，也不去找 profile 名、凭证、provider 配置、CDP 端点或控制面标识。

原因是恢复。运行时拥有 daemon supervisor、materializer 和会话恢复路径。第二个所有者——agent 拉起的 Chromium，或 agent 打开的 CDP 连接——在这条路径之外。运行时要恢复、检查点或拆除会话时，看不到也控制不了 agent 的旁路通道，于是会话进入不一致状态。预配置的 CLI 是唯一且受管的入口，也是 agent 唯一该碰的。

## agent 如何驱动浏览器

`ankole-browser` CLI 给 agent 三种执行面，按工作形态挑选：

- **短 CLI 命令**用于探索和一两个确定性动作——`open`、`snapshot -i`、`click @e2`、`fill @e4 "value"`、`screenshot`。
- **`batch`** 用于已知的短序列，接收引号包裹的命令，或 stdin 上的 argv 数组的数组，套用与单条命令相同的解析器。
- **`run`** 用于 ESM JavaScript 文件，当任务需要循环、分支、重复抽取、弹窗/下载/响应协调、精确等待，或要在内存里保留多个值时。`run` 把原生 Playwright 对象挂到 CLI 命令使用的同一个物理浏览器会话上，所以脚本和 CLI 步骤共享一个会话。

最后这点很重要：`run` 不开第二个浏览器。它复用运行时拥有的会话，所以即使在 Playwright 脚本里，单一所有者规则也成立。

## 运维不该碰的东西

浏览器的环境变量由 worker 镜像设置，不是运维可调的。它们包括 `ANKOLE_BROWSER_CHROMIUM_EXECUTABLE`、`ANKOLE_BROWSER_CHROMIUM_ARGS_JSON`、`ANKOLE_BROWSER_DAEMON_SOCKET`、`ANKOLE_BROWSER_DAEMON_ENTRY`、`ANKOLE_BROWSER_CLI`、`ANKOLE_BROWSER_NODE`、`ANKOLE_BROWSER_RUNNER`。这些名称不能在 Console 的“环境变量”中覆盖。如果需要不同的浏览器行为，请修改 Skill。

## 下一步

- 打开浏览器所依赖的 skill 与启用模型，读 [Agent Library](../agent-library/)。
- 更轻的替代方案——不带浏览器的搜索与文本 fetch——读 [Web 工具](../web-tools/)。
- 浏览器所在的后台任务，读 [后台 Agent 任务](../background-jobs/)。
