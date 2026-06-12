# Browser Runtime With Camoufox And Webwright

BullX 的浏览器能力应该是自有的 browser tools 和自有 CLI，而不是 BrowserAct、Webwright skill 或 MCP。底层浏览器优先评估 Camoufox，交互模型吸收 Webwright 的 code-as-action 工作区约束：agent 通过 browser tools 调用 computer 内的 `bullx-browser`，浏览器只是可启动、可检查、可丢弃的执行环境。

这个设计只有在 worker image 或 worker volume 提供 `/opt/camoufox` 浏览器二进制，并且 Docker smoke、CLI smoke、tool smoke、LLM E2E 都通过后，worker 才能广告 `browser` feature。

## Runtime Contract

browser tools 的对外语义属于 BullX：

- 默认优先使用 `web_search` 和 `web_extract` 处理无状态搜索、简单页面读取和普通内容抽取。
- 只有状态化浏览、登录/session 工作流、表单、截图、需要浏览器渲染的页面、或 `web_extract` 被爬虫限制阻断时，才使用 computer 内的浏览器 CLI。
- BrowserAct、Camoufox、Webwright 都不能出现在 agent 面向用户的能力名里。它们最多是实现细节。

system prompt 已经提供 Agent UID。browser tools 默认使用这个 UID 作为 artifact namespace。profile state 由 `profileMode` 决定：

- `ephemeral`: 一次性渲染查看或 `web_extract` fallback，不复用 cookies、localStorage、登录态。
- `persistent`: 登录/session 工作流、连续点击、表单、多步任务，复用同一 agent/session profile。

`browser_open` 和 `browser_extract(url)` 默认 `ephemeral`。`browser_run` 默认 `persistent`，因为它是多步/stateful 工作主路径。同一 agent 的第二个独立持久浏览器任务可以传入 session 短后缀，例如 `<agent_uid>-checkout`。

## Engine Constraint

Camoufox 官方 README 将它定义为用于 web scraping 和 AI agents 的 Firefox fork，并提供 Python 接口包装 Playwright API。这里的“不用 Firefox”按工程约束解释为：不安装通用 Playwright Firefox，不走 BrowserAct 的 Firefox/Camoufox 下载链路，也不把 Playwright Firefox 当 fallback。

如果约束升级为“不能使用任何 Firefox-derived 浏览器二进制”，Camoufox 本身不满足要求，浏览器方案必须停止在 Camoufox 方向并重新选 Chromium-family 引擎。实现前必须由 smoke test 明确记录当前解释。

## CLI Shape

新增 system CLI：`bullx-browser`。它是 BullX-owned wrapper，内部可以使用 Camoufox Python API、Playwright API、以及从 Webwright 迁移来的工作区约束。

app 层暴露少量 browser tools。tools 负责参数结构化、Agent UID session 默认值、computer worker/session 解析和 CLI 调用；agent 不直接拼 shell：

- `browser_doctor`
- `browser_open`
- `browser_extract`
- `browser_run`

CLI 命令面：

```bash
bullx-browser doctor
bullx-browser open --session "$BULLX_BROWSER_SESSION" --url https://example.com
bullx-browser extract --session "$BULLX_BROWSER_SESSION" --url https://example.com
bullx-browser run --session "$BULLX_BROWSER_SESSION" --script /workspace/user-files/browser/tasks/task.py
```

`browser_run` / `bullx-browser run` 是复杂任务主路径。它执行 agent 写出的 Python 脚本，并把 Webwright 风格的 artifacts 写入 agent workspace：

- `/workspace/user-files/.bullx/browser/profiles/<agent_uid>/`
- `/workspace/user-files/browser/tasks/<task_id>/plan.md`
- `/workspace/user-files/browser/tasks/<task_id>/final_script.py`
- `/workspace/user-files/browser/tasks/<task_id>/final_runs/run_<n>/`
- `/workspace/user-files/browser/tasks/<task_id>/final_runs/run_<n>/screenshots/`
- `/workspace/user-files/browser/tasks/<task_id>/final_runs/run_<n>/final_script_log.txt`

`browser_open` 和 `browser_extract` 服务常见渲染读取和探索，默认不污染长期 profile。完成多步任务的可审计结果必须落在 `final_script.py` 和 run artifacts 里。

## Webwright Integration

Webwright 的价值是工作方式，不是要把它作为独立 agent loop 跑进 BullX：

- 复用它的 workspace-as-state 模型：浏览器 session 不是唯一状态，脚本、日志、截图和 plan 才是可审计状态。
- 复用它的 final-run 约束：每次干净执行都有独立 `run_<n>`，截图和日志证明每个关键点。
- 不复用它的模型调用层。BullX agent 已经有自己的 LLM runtime，不需要 Webwright 再调用 OpenAI、Anthropic 或 OpenRouter。
- 不照搬默认浏览器。Webwright README 默认安装 Playwright Chromium，skill adaptation 里也有 Firefox launch skeleton；BullX 的 engine 由 `bullx-browser` 统一封装为 Camoufox。

## Docker Image

浏览器 runtime 应该继续走 system-level baseline，而不是每 agent 一个预制 venv：

- 在 computer image build 阶段安装 `camoufox[geoip]` 或稳定 pin 的等价包。
- 默认不依赖 build 阶段执行 `python -m camoufox fetch`。Camoufox 官方 fetch 不支持断点续传，worker image 或运维层应该把固定 release asset 预装到 `/opt/camoufox`。`bullx-browser` 在 agent 首次使用时把 `/opt/camoufox` 复制到当前 `HOME/.cache/camoufox`，使浏览器 cache 保持在 agent 可写状态下。
- 安装 Camoufox 需要的 Linux system libraries、fonts、`xvfb` 或等价 virtual display 支持。
- 安装 Webwright 代码依赖中实际需要的 `playwright`, `pydantic`, `pyyaml`, `typer`, `httpx`；不启用它的模型 provider 配置。
- 不安装 BrowserAct。
- 不安装通用 Playwright Firefox。

`/usr` 和 `/opt` 在 bubblewrap 内只读。agent profile、cookies、screenshots、scripts、downloads 只写入 `/workspace/user-files`。

## Tool Behavior

browser tools 默认可随 computer tools 出现，但 tool description 必须明确限制使用场景：

- 无状态搜索：用 `web_search`。
- 简单网页读取：用 `web_extract`。
- 需要登录、连续点击、表单、截图、下载、复杂 JS 渲染、或 `web_extract` 被限制：用 `browser`。

tool 层核心行为：

- 默认 artifact session 来自 Agent UID。
- 默认 profile mode 按工具区分：`browser_open` / `browser_extract(url)` 用 `ephemeral`，`browser_run` 用 `persistent`。
- `browser_open` 保存截图、html、text 和 metadata。
- `browser_extract` 读取 URL 或 latest capture 的 rendered text。
- `browser_run` 写入 agent 提供的 Python script，执行并保存 `final_runs/run_<n>/` artifacts。
- 如果页面阻断、验证码或登录要求出现，报告证据，不要退回无状态 extract 假装完成。

## Implementation Surfaces

- `packages/computer/docker/Dockerfile`: 安装 Camoufox package、system dependencies、`bullx-browser`。
- `packages/computer/src/config.rs`: 只有 browser binary smoke 通过后才把 default features 加回 `browser`。
- `packages/computer/docker/docker-compose.yml`, `tools/devkit/external-services.docker-compose.yml`: 同步 feature advertisement。
- `packages/computer/browser/`: 放 `bullx-browser` Python wrapper。
- `app/src/ai-agent/tools/browser/`: BullX browser tools，不暴露 BrowserAct、Camoufox 或 Webwright 作为能力名。
- `app/scripts/llm-e2e.ts`: 增加 LLM 通过 computer 访问 Wikipedia 或 example 页面并验证截图/标题的场景。

## Verification

Docker smoke:

```bash
python - <<'PY'
from camoufox.async_api import AsyncCamoufox
print("camoufox import ok")
PY
bullx-browser doctor
```

Browser smoke:

```bash
browser_run / bullx-browser run \
  --session smoke-agent \
  --script /workspace/user-files/browser/tasks/smoke_wikipedia.py
```

smoke script 必须 headless/virtual-display 打开 Wikipedia 页面，验证 title 或 heading 包含 `Wikipedia`，保存截图，并输出 `BULLX_BROWSER_WIKIPEDIA_SMOKE_OK`。

Agent/LLM E2E:

- 让模型直接调用 `browser_open` 或 `browser_run` 访问 Wikipedia。
- 断言 tool result 里有 smoke sentinel、截图路径、最终 URL、页面标题。
- 单独跑 `web_extract` 被限制的模拟场景，验证 browser tools 是 fallback 而不是默认路径。

## Binary acquisition and readiness

- Local smoke verified Camoufox `135.0.1-beta.24` Linux arm64 by downloading the fixed release asset with `aria2c`, installing it at `/opt/camoufox`, bootstrapping it into the agent cache, and opening `https://www.wikipedia.org/` through `browser_open`.
- `python -m camoufox fetch` can still be used manually through `browser_doctor(fetch=true)`, but it should not be the default production path because the one-shot download can fail mid-stream and discard partial progress.
- A worker should advertise `browser` only when `bullx-browser --json doctor` reports `ready=true` in the same isolation mode used for agent commands.
- 如果产品要求完全禁止 Firefox-derived browser，Camoufox 方向不成立。

## Context pointers

- [Camoufox README](https://github.com/daijro/camoufox)
- [Camoufox Python interface](https://github.com/daijro/camoufox/tree/main/pythonlib)
- [Webwright README](https://github.com/microsoft/Webwright)
- [Webwright skill adaptation](https://github.com/microsoft/Webwright/blob/main/skills/webwright/SKILL.md)
