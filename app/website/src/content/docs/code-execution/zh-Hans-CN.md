---
title: 代码执行
description: Ankole Agent 如何在普通对话和持久的后台 Agent 任务中运行代码。
section: Developer guide
order: 122
---

Agent 可以在普通对话中运行命令、读写文件，也可以把需要持续执行的工作交给后台 Agent 任务。两者走不同的运行路径：普通对话使用 Agent Computer Worker 的前台工具，每个后台 Agent 任务则由 CodexRunner 执行。消息里有多少代码，不会触发运行路径切换。

先说明最关键的一点：每条命令都在沙箱里跑。shell 命令跑在 bubblewrap 下，带 `SYS_ADMIN`、不限制的 seccomp、不屏蔽的 `/proc`——这是 worker 的硬性要求，不是运维的选择。agent 在 `/agents` 下的按 agent 文件系统里工作，shell 无法让它逃出这个沙箱。

## bubblewrap 下的 shell 命令

agent 通过 command 工具跑 shell 命令，由 `app/agent_computer/src/tools/computer/command-tool.ts` 和 `bubblewrap.ts` 里的 bubblewrap 沙箱支撑。模型请求的每条命令都跑在 bubblewrap 下，带 `SYS_ADMIN`、不限制的 seccomp 策略、不屏蔽的 `/proc`。不屏蔽的 `/proc` 和 `SYS_ADMIN` 能力是让更深的工具——[浏览器](../browser-automation/) daemon、Jupyter kernel——能在同一个沙箱里跑，而不是逃出沙箱。这套组合是 worker 镜像的硬性要求，见 [快速开始](../quickstart/#deployment)；它不是按 agent 可调的。

实践上意味着：一条 shell 命令能读写 agent 工作区下的文件、跑已装的工具、启动 worker 镜像提供的子进程。它够不到别的 agent 的工作区，也够不到控制面状态。沙箱就是边界。

## 文件读取与 apply_patch

shell 之外，computer 工具给 Agent 两个文件原语：

- **读文件**——`read-file-tool.ts`，直接看一个文件的内容，而不是开 shell 跑 `cat`。
- **编辑文件**——`apply-patch-tool.ts`，提供与固定 Codex 版本相同语法的 freeform `apply_patch` 工具。

Main Agent 通过 AIGateway 把原始 patch 作为 `custom_tool_call` 发送。Worker 再通过 `/usr/local/bin/apply_patch` 交给 Codex 原生二进制。后台 Agent 任务从 AIGateway 模型卡获得同一个 freeform 工具，也使用同一个二进制。Ankole 不再维护另一套 patch 解析器。

这条共享路径让普通对话和后台 Agent 任务使用同一种编辑协议。patch 无法匹配时，原生工具会失败，并把失败结果返回给模型。快速搜索可以用 shell；文件编辑使用 `apply_patch`。

## /agents 文件系统

agent 读写的一切都在 `/agents` 下，按 agent key 布局。agent 直接看到容器路径——worker 不为模型翻译路径：

```text
/agents/<agent-key>/
├── SOUL.md
├── MISSION.md
├── DESIGN.md
├── user-files/
├── installed-skills/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── AGENTS.md
    └── temp/
```

`SOUL.md`、`MISSION.md` 和 `DESIGN.md` 是 [Agent Library](../agent-library/) 中的长期文档。前两份定义职责与行为，`DESIGN.md` 是视觉内容使用的设计系统。`installed-skills/` 存放 Agent 安装的 Skill。`sessions/` 使用由 PostgreSQL 从 10000 开始分配的稳定数字 ID 保存普通会话工作区，`jobs/` 是后台 Agent 任务的独立工作区。

后台 Agent Job 通过 Ankole `skill_view` 加载 Skill，不会把 Skill root 复制到 Job 工作区。

## 迭代 Python 用的 Jupyter live kernel

当工作是迭代 Python——变量要跨执行保留、要逐 cell 检查 DataFrame、或要一个有状态的 REPL——shell 是错的工具。`jupyter-live-kernel` skill 才是对的。它是内置 skill（`default_enabled: true`），作为 [后台任务](../background-jobs/) 运行，建立在 Ankole 围绕 hamelnb 的 Unix-socket 适配器之上。kernel 跨执行保持存活，所以你能在一步里定义变量、下一步读它，而不是每次调用都重新装载数据。

skill 自带的指引是经验法则：短小、无状态的 Python 脚本优先用一次性 shell 执行；当你本来需要 Jupyter notebook 或有状态 Python REPL 时，用这个 skill。数据科学、DataFrame 检查、notebook 编辑、有状态 API 探索是它最擅长的场景。系统 Python、JupyterLab、ipykernel 和 hamelnb 助手已经在 worker 镜像里，所以新 agent 不装任何东西就能用这个 skill。

## 后台 Agent 任务使用 CodexRunner

CodexRunner 是所有后台 Agent 任务的执行引擎。任务可以是调研、制作文档、修改代码仓库，也可以是其他需要持续运行的工作。决定是否使用 CodexRunner 的是任务的生命周期，而不是任务内容。Runner 通过 `app-server-client.ts` 与 Codex app-server 通信，并为每个任务准备独立的工作区和运行配置。

Console 将对应的模型档案显示为**后台 Agent 任务**。它在数据库和 API 中暂时仍使用 `coding` 这个历史名称，但这不表示普通对话会在代码较多时自动切换模型。

## Ankole 如何选择运行路径

需要配置的内容很少：

- **Computer 工具**（`command`、`read_file` 和 `apply_patch`）随每个 Worker 提供，普通对话可以直接使用。
- **Jupyter live kernel** 是 `default_enabled` skill，所以你通过 [Agent Library](../agent-library/) 控制它，方式和控制 [浏览器](../browser-automation/) skill 一样。为不该跑迭代 Python 的 agent 收窄它。
- **CodexRunner** 执行每个后台 Agent 任务，所有模型调用都通过 AIGateway。后台任务需要不同 Provider 或模型时，配置“后台 Agent 任务”档案；留空时，控制面使用该 Agent 的 `heavy` 档案。

## 下一步

- 跑这些工具、拥有 `/agents` 文件系统的 Worker，读 [Agent Computer Worker](../agent-computer-worker/)。
- Jupyter skill 背后的 skill 与启用模型，读 [Agent Library](../agent-library/)。
- 后台 Agent 任务档案及其内部键 `coding`，读 [后台 Agent 任务](../background-jobs/#选择模型-provider)。
- worker 镜像要求的沙箱，读 [快速开始](../quickstart/#deployment)。
