---
title: Web 工具
description: Ankole agent 如何搜索和抓取公开网络——web_search 与 web_fetch 工具、它们的可用性如何依赖 model profile 绑定、web_fetch 的 1-5 个公开 HTTPS URL 限制、渲染态 fetch 缓存，以及何时用这些工具而不是浏览器。
section: User guide
order: 32
---

Web 工具是 agent 触达公开网络的轻量方式：搜索，以及抓取页面的可读文本。它们是 `web_search` 和 `web_fetch` 工具，定义在 `app/agent_computer/src/tools/web/web-tools.ts`，跑在回合内、经 AIGateway，而不是驱动浏览器。本页是运维视角——这两个工具做什么、要让它们出现需要配什么、什么时候用它们而不是用[浏览器](../browser-automation/)。

先把决定性的性质说清楚：这两个工具只有在对应 model profile 已绑定时才存在。profile 是一个选择器，控制面在调用时把它解析成真实 provider，agent 永远看不到凭证。`web_search` 或 `web_fetch` profile 未设，对应工具就直接不出现在该回合的工具集里。

## 每个工具做什么

- **`web_search`** 通过配置好的 AIGateway web 搜索 provider 搜索公开网络。agent 给一个 query，拿回搜索结果。
- **`web_fetch`** 通过 AIGateway 从 HTTPS 网页抽取并返回可读文本，provider 不可用时有一个内部渲染态页面回退。agent 传入需要的 URL，拿回页面文本。

两个工具都是只读——`web_search` 是 `isReadOnly: true`，`web_fetch` 也是。两者都不向网络写任何东西。`web_search` 可与其他并行工具并发；`web_fetch` 是顺序的。

## 你必须配什么

这两个工具不是无条件的。它们的可用性依赖 agent 上 `web_search` 和 `web_fetch` model profile 已绑定，正是 [Providers 与模型](../providers-and-models/)里列的那两个槽位。两个后果：

1. **没绑定就没工具。** `web_search` profile 未设，`web_search` 就不出现在该回合的工具集里；`web_fetch` 同理。这就是为什么一个没接到 web provider 的新 agent 不能搜索——那个工具对模型来说真的不存在。
2. **绑定是选择器，不是凭证。** profile 指向你通过 `PUT /ai-gateway/providers/<id>` 配过的 provider id，凭证加密存在那个 provider 的 `options` 里。控制面在调用时解析选择器；agent 和 worker 都看不到凭证。

通过 Console 绑定 profile，用的是和推理槽位一样的 `PUT /agents/:agent_uid/model-profiles/<profile>` 路由。如果某回合的 web 调用以 `422 unknown_model_selector` 或 `422 model_binding_not_configured` 失败，原因是绑定，不是瞬时故障——确认 profile 指向的 provider id 确实存在且 options 完整。

## web_fetch：1 到 5 个公开 HTTPS URL

`web_fetch` 一次调用接收一到五个 URL，且必须是公开 HTTPS。一到五个的限制和仅 HTTPS 的规则都是刻意的：这个工具用来读公开网页，把几个 URL 打包成一次调用让回合更高效。它只返回文本，绝不返回二进制内容。不要用它取 PDF、压缩包、图片、音频视频、可执行文件或其他二进制文件；这类下载 agent 用命令 shell 跑 `aria2c`。

provider 路径在已配置时优先，因为网关可以用自有的抽取服务。provider 不可用时，内部渲染态页面回退让渲染过的页面仍可达，所以一次 fetch 不会因为 provider 下线就静默失败。

## 渲染态 fetch 缓存

经渲染路径抓取的结果会被缓存，这样 agent 不会在一个回合里把同一页渲染两次。缓存寿命由 `worker.rendered_fetch_idle_ttl_ms` 这个 AppConfigure key 控制，它设定一个空闲的渲染态 fetch 结果保留多久。如果你发现 agent 在重复抓取它已经看过的页面，或者想缩短缓存以强制拿到更新鲜的结果，通过 AppConfigure 调它。默认值对大多数工作合理；只有当访问模式需要时才改。

## 何时用 web 工具而不是浏览器

这是 agent 在每个回合都要做的选择。[浏览器 skill](../browser-automation/) 自己把规则说清楚了：当不需要渲染交互、登录态、截图、浏览器侧代码时，优先用 `web_search` 和 `web_fetch`。

具体地：

- **用 web 工具**找一个页面、读它的文本，或在一个回合里收集几页内容。它们更便宜更快，也不占用浏览器会话。
- **用浏览器**当页面只有在 JavaScript 跑完、点击或填写后才给出数据，当你需要持久登录会话，当你需要截图，或当你需要可复现的 Playwright 工作流。

如果你在配一个工作主要是读公开页面的 agent，确保 `web_search` 和 `web_fetch` profile 已绑定，浏览器 skill 保持默认。如果 agent 还要与登录后的站点交互，再开启浏览器。两条路径共存；它们不是对整个 agent 二选一，而是对每个任务二选一。

## 下一步

- 这两个工具依赖的 profile 槽位，读 [Providers 与模型](../providers-and-models/)。
- 更重的路径——真实浏览器交互——读[浏览器自动化](../browser-automation/)。
- 回合如何每回合组装这些工具，读[工具运行时](../tools-runtime/)开发页。
- 绑定 profile 的路由，读 [Console API 参考](../console-api/)。
