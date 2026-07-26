---
title: 代码执行
description: Ankole agent 如何运行代码——bubblewrap 沙箱里的 shell 命令、文件读取与 patch、apply-patch 工作流、/agents 文件系统布局、迭代 Python 用的 Jupyter live-kernel skill，以及处理重代码回合的 CodexRunner。
section: User guide
order: 31
---

代码执行是 agent 在运行命令、编辑文件，或通过真实代码来回答问题、完成任务时所做的事。在 Ankole 里，这是 Agent Computer 自带的一组 computer 工具，加上两条更重的、用于迭代和重代码工作的路径：Jupyter live-kernel skill 和 CodexRunner。本页是这三者的运维视角。

先把决定性的性质说清楚：每条命令都在沙箱里跑。shell 命令跑在 bubblewrap 下，带 `SYS_ADMIN`、不限制的 seccomp、不屏蔽的 `/proc`——这是 worker 的硬性要求，不是运维的选择。agent 在 `/agents` 下的按 agent 文件系统里工作，shell 无法让它逃出这个沙箱。

## bubblewrap 下的 shell 命令

agent 通过 command 工具跑 shell 命令，由 `app/agent_computer/src/tools/computer/command-tool.ts` 和 `bubblewrap.ts` 里的 bubblewrap 沙箱支撑。模型请求的每条命令都跑在 bubblewrap 下，带 `SYS_ADMIN`、不限制的 seccomp 策略、不屏蔽的 `/proc`。不屏蔽的 `/proc` 和 `SYS_ADMIN` 能力是让更深的工具——[浏览器](../browser-automation/) daemon、Jupyter kernel——能在同一个沙箱里跑，而不是被破出沙箱。这套组合是 worker 镜像的硬性要求，见[安装](../installation/)和[平台支持](../platform-support/)；你不按 agent 调它。

实践上意味着：一条 shell 命令能读写 agent 工作区下的文件、跑已装的工具、启动 worker 镜像提供的子进程。它够不到别的 agent 的工作区，也够不到控制面状态。沙箱就是边界。

## 文件读取、patch、apply-patch

shell 之外，computer 工具给 agent 几个结构化文件原语，每个在 `app/agent_computer/src/tools/computer/` 里对应一个工具：

- **读文件**——`read-file-tool.ts`，直接看一个文件的内容，而不是开 shell 跑 `cat`。
- **patch 文件**——`patch-tool.ts`，对一个已存在文件施加定向编辑。
- **CLI 上的 apply-patch**——`apply-patch-cli.ts`，agent 对更大的结构化改动用的 apply-patch 工作流。

这些原语存在的理由是：自由形式的 shell 编辑很脆弱——模型可能在空白上漂移、重复一块、或漏掉一个闭合大括号。patch 工具收结构化的编辑描述，所以一次失败的编辑干净地失败，而不是把文件搞坏。一行读取或快速 `grep` 用 shell 就好；真正的编辑用 patch 工具更安全。

## /agents 文件系统

agent 读写的一切都在 `/agents` 下，按 agent key 布局。agent 直接看到容器路径——worker 不为模型翻译路径：

```text
/agents/<agent-key>/
├── SOUL.md
├── MISSION.md
├── DESIGN.md
├── user-files/
├── installed-skills/
├── sessions/<base64url-session-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── .ankole/skills/
    └── temp/
```

persona 文档——`SOUL.md`、`MISSION.md`、`DESIGN.md`——是 [Agent Library](../agent-library/) 暴露的 agent 自有库文档。`installed-skills/` 放 agent 安装的 skill 包。`sessions/` 是按会话的工作区，`jobs/` 是后台工作的按任务工作区，里面还有重代码任务用的 Codex 配置。与控制面之间的文件传输走专用文件通道，不走 RPC 通道。

## 迭代 Python 用的 Jupyter live kernel

当工作是迭代 Python——变量要跨执行保留、要逐 cell 检查 DataFrame、或要一个有状态的 REPL——shell 是错的工具。`jupyter-live-kernel` skill 才是对的。它是内置 skill（`default_enabled: true`），作为[后台任务](../background-jobs-ops/)运行，建立在 Ankole 围绕 hamelnb 的 Unix-socket 适配器之上。kernel 跨执行保持存活，所以你能在一步里定义变量、下一步读它，而不是每次调用都重新装载数据。

skill 自带的指引是经验法则：短小、无状态的 Python 脚本优先用一次性 shell 执行；当你本来会想要 Jupyter notebook 或有状态 Python REPL 时，用这个 skill。数据科学、DataFrame 检查、notebook 编辑、有状态 API 探索是它的甜区。系统 Python、JupyterLab、ipykernel 和 hamelnb 助手已经在 worker 镜像里，所以新 agent 不装任何东西就能用这个 skill。

## 重代码回合的 CodexRunner

当一个回合的核心是写或改大量代码时，Ankole 通过 CodexRunner 路由工作——`app/agent_computer/src/tools/codex/` 里的 Codex app-server 集成。runner 通过 `app-server-client.ts` 与 Codex app-server 通信，带自己的沙箱和运行时配置，所以重代码回合跑在 Codex 执行模型上，而不是普通 shell 上。这正是 `coding` model profile 槽位要服务的路径；那个槽位如何绑定见 [Providers 与模型](../providers-and-models/)。

CodexRunner 用于持续的、代码形态的工作——重构、多文件特性、需要好几次工具迭代的调试会话。单条命令或一次快速文件读取，shell 和 patch 工具更便宜更快，agent 应该先够它们。

## 如何启用这三条路径

三条路径默认都开着，运维面很窄：

- **computer 工具**（shell、read-file、patch）随每个 worker 出厂——没有启用项可设。Agent Computer 跑的每个回合都可用。
- **Jupyter live kernel** 是 `default_enabled` skill，所以你通过 [Agent Library](../agent-library/) 控制它，方式和控制[浏览器](../browser-automation/) skill 一样。为不该跑迭代 Python 的 agent 收窄它。
- **CodexRunner** 接在 worker 里，回合变重代码时自动启用。要配的是 agent 的 `coding` model profile，让 runner 有模型可调；没有这个绑定，重代码回合解析不出模型。

## 下一步

- 跑这些工具、拥有 `/agents` 文件系统的 worker，读 [Agent Computer](../agent-computer/)。
- Jupyter skill 背后的 skill 与启用模型，读 [Agent Library](../agent-library/)。
- CodexRunner 用的 `coding` profile 槽位，读 [Providers 与模型](../providers-and-models/)。
- worker 镜像要求的沙箱，读[安装](../installation/)和[平台支持](../platform-support/)。
