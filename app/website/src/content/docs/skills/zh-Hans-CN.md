---
title: Skills
description: Ankole agent 在运行时如何使用 skill——worker 工具（skill_view、skill_append、skill_replace）、五个内置 skill、default-then-override 启用模型，以及运维如何为 agent 开关一个 skill。
section: User guide
order: 34
---

skill 是一个带 `SKILL.md` 的文件系统 bundle，教 agent 怎么干一类活。agent 不会在运行时凭空造 skill；它读 [Agent Library](../agent-library/) 已经启用的那些，从中学习，再把学到的东西记回去。本页是 skill 使用中的运维视角：worker 工具有哪些、出厂带什么、agent 何时读、何时写、你如何开关一个 skill。

先把决定性的性质说清楚：skill 是文件系统 bundle，不是数据库行。bundle 装着指令和资源；数据库只存启用状态，以及一层稀疏的、按 agent 的覆盖层——那是 agent 用 skill 时加的笔记。skill 自己的 `SKILL.md` 是模型读的契约；覆盖层是 agent 在其之上加的东西。

## skill 是什么

skill 是一个根目录带 `SKILL.md` 的目录，由 [Agent Library](../agent-library/) 发现。`SKILL.md` 是 frontmatter 加 Markdown 正文。frontmatter 装运行时要的东西：

- **`default_enabled`**——除非被覆盖收窄，否则这个 skill 对每个 agent 默认开。
- **`ankole-runtime: background_job`**——一个标记，表示这个 skill 的活跑成[后台任务](../background-jobs-ops/)，与拥有它的回合隔离，而不是内联跑。

正文是指令。内联 skill：agent 在判断任务需要它时读 `SKILL.md` 和被引用的文件。后台任务 skill：agent 只读 `SKILL.md`，里面带路由指引，真正的活在后台任务里跑。

## 出厂带什么

`app/library/skills/` 下出厂带五个 skill，覆盖 agent 大概率需要的重路径：

- **`browser`**——通过 `ankole-browser` CLI 驱动运行时拥有的 Chromium 会话做浏览器自动化。见[浏览器自动化](../browser-automation/)。
- **`brain-review`**——对 Brain 记忆做对话式的事后复盘。只在人类明确要求复盘、审计、清理、或 复盘 agent 的记忆时才跑。见[记忆](../memory/)。
- **`design-md`**——视觉产物与 VIS 设计。
- **`jupyter-live-kernel`**——通过一个跨执行存活的 Jupyter kernel 跑迭代 Python。见[代码执行](../code-execution/)。
- **`pdf`**——创建、检查、编辑 PDF 文件。

除非运维收窄，每个都是 `default_enabled` 的内置 skill，所以新建的 agent 默认就有。想看 skill 长什么样，它们就是规范的样例。

## agent 如何读 skill

worker 出厂带三个 skill 工具，都在 `app/agent_computer/src/tools/library/skill-tools.ts`。它们是 agent 触达 skill 内容的唯一界面：

- **`skill_view`**（第 75 行）——读一个已启用 skill 的文件。对 `background_job` skill 只返回路由指引并拒绝引用的资源；对内联 skill 只在需要时读引用文件，从返回的 skill 目录解析相对路径。它是只读的，description 说得很直白：这个工具启用不了被禁用的 skill。
- **`skill_append`**（第 123 行）——往这个 agent 对某已启用 skill 的、数据库支撑的覆盖层追加一条持久笔记。控制面拥有读-改-写事务，所以并发回合不会互相丢更新。
- **`skill_replace`**（第 152 行）——替换某个 skill 的整个覆盖层，用最新的已解析内容哈希做乐观比较-交换栅栏。并发的改动会被拒，而不是被静默覆盖。

覆盖层是关键概念。skill bundle 本身不是按 agent 的——每个启用了它的 agent 共享同一份。按 agent 的是 agent 用它时加的那层笔记：更正、本地约定、踩过的坑。`skill_append` 往这层加；`skill_replace` 重写它。bundle 留在文件系统里；覆盖层作为稀疏的按 agent 状态存在 PostgreSQL 里。

## agent 何时用哪个工具

工作的形态决定用哪个：

- **`skill_view`**——agent 要做 skill 覆盖的任何事之前。先读 `SKILL.md` 学流程，再按流程需要读引用文件。
- **`skill_append`**——agent 在这个 agent 的上下文里，对这个 skill 学到了持久的东西：一条本地约定、一个更正的步骤、一个坑。description 告诉模型：只有在读完 skill 之后、且只加在使用中习得的按 agent 内容时才用。
- **`skill_replace`**——用于修订、去重、或为保预算而压缩：当覆盖层涨过了 memo 预算，或 agent 学得够多、可以改得更紧。先读 skill；另一回合的并发改动会被拒。

agent 不启用也不禁用 skill。那是控制面决定，通过 [Agent Library](../agent-library/) 做的。worker 工具只读和注解。

## 如何启用 skill

skill 由 default-then-override 模型管，按 agent 解析。两层：

1. **安装级默认值**——skill `SKILL.md` 里的 `default_enabled`。一个 `default_enabled: true` 的内置 skill 对每个 agent 都开。
2. **按 agent 覆盖**——为不该有它的 agent 收窄，或为你之前收窄过的放开。Console 的 library-capability 路由设这个；读某个 agent 的 `library-capabilities` 会触发一次 skill 同步，所以你看到的是注册表对当前文件系统重对账后的结果，不是过期快照。

解析结果就是能力端点返回的 `effective_enabled` 字段：取默认值，若有覆盖就套用。没覆盖的 skill 继承默认值；有覆盖的尊重覆盖。

对后台任务 skill，启用是必要但不充分——worker 还得能跑后台任务，那是一块独立的界面。见[后台任务（运维视角）](../background-jobs-ops/)。

## 运维不该碰的东西

skill bundle 的文件、覆盖层的内容哈希栅栏、`/agents` 下的文件系统布局，都不是运维可调的。如果某个 skill 行为不对，修在 `SKILL.md` 里，而不是某个 worker 环境变量。覆盖层是 agent 自有的状态：运维不手改它——agent 通过自己的工具追加和替换，对它的人类复核走的是同一个 worker 界面。

## 下一步

- 决定哪些 skill 开着的目录与启用模型，读 [Agent Library](../agent-library/) 开发者页。
- 如何新写一个 skill，读 [Writing a skill](../writing-a-skill/)。
- 记忆复盘 skill 以及它复盘什么，读[记忆](../memory/)。
- 跑这些工具的 worker，读 [Agent Computer](../agent-computer/) 开发者页。
