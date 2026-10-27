---
title: 代码执行
description: Ankole Agent 如何在日常对话与持久化后台 Agent 任务中运行命令、编辑文件与执行代码。
section: Developer guide
order: 122
---

Ankole Agent 既可以在日常对话中直接运行终端命令、读写与修改文件，也可以把耗时较长的开发与分析工作委派给后台 Agent 任务。这两类场景走的是两条不同的执行链路：日常对话调用 Agent Computer Worker 的前台电脑工具，而每个后台 Agent 任务则交由 `CodexRunner` 驱动执行。顺带一提，用户在消息里贴了多少行代码并不会触发执行链路切换——走前台还是走后台，完全取决于工作本身的生命周期形态。

先明确最核心的隔离前提：**每个 Agent 的每一条命令都在它专属的电脑上运行。**每个 Agent 都独占一个 Worker 容器实例，容器本身就是唯一的隔离边界：命令直接以 Worker 容器内的普通用户身份运行，不套额外的内层沙箱，Agent 在 `/workspace` 下的专属 Agent Home 目录中自由开展工作。它可以任意修改自己这台电脑里的工作区环境，但与其他 Agent 之间绝不共享 Worker 实例、本地缓存盘或任何访问凭据。与之相对，Pod Applet 的后端函数以及 AIGateway 和 Workflow 中的编程式工具调用（PTC）脚本，则运行在无状态的 `ankole-function-runtime` 隔离实例（isolate）中，不在 Agent Computer Worker 上执行。

## shell 命令

Agent 通过内置的 `command` 工具执行 Shell 命令（底层由 `app/agent_computer/src/tools/computer/command-tool.ts` 实现）。每条命令都以 Worker 用户身份在独立的进程组内启动，并使用一份剥离了 Worker 平台通信凭据的干净环境变量；一旦收到取消指令或达到超时上限（前台命令默认时限为 180 秒），系统会整组清理整个进程组。所有命令的工作目录都必须位于 Agent Home 边界之内。与此同时，[浏览器自动化](../browser-automation/)守护进程、Codex `app-server` 以及 Automation 脚本也同样以该普通用户身份运行，无需为容器赋予任何特权级内核能力。

具体而言，所有命令均以 `uid 1000` 运行且不提供 `sudo`：Agent 可以在自己的 Home 目录内读写文件、安装用户态依赖包或派生子进程，但无法改动系统级软件包。同一个 Agent 名下的前台 Session 与后台 Job 可以互访彼此保存在 Home 中的文件，而不同 Agent 之间则由独立的容器实例彻底隔离。此外，Worker 容器既不直连控制面数据库，也不持有底层对象存储桶的密钥。

## 文件读取与 apply_patch

除通用 Shell 命令外，电脑工具集还为 Agent 提供了两个专门的文件操作原语：

- **读取文件**（`read-file-tool.ts`）：直接按路径读取文件内容，无需每次派生一个 Shell 子进程去跑 `cat`。
- **增量打补丁编辑**（`apply-patch-tool.ts`）：提供与所锁定 Codex 版本语法完全一致的自由格式（freeform）`apply_patch` 工具。

在前台主 Agent 循环中，模型通过 AIGateway 将原始补丁文本作为 `custom_tool_call` 发出，Worker 收到后直接调用容器内的 `/usr/local/bin/apply_patch` 原生二进制完成修改；而在后台 Agent 任务中，模型同样从 AIGateway 模型能力卡拿到这同一个自由格式工具，并在底层调用同一个原生二进制。

依靠这条统一的底层通路，日常前台对话与长时后台任务得以共用完全一致的文件编辑协议。一旦补丁上下文无法精确匹配目标文件，原生工具会直接报错终止并将原因如实反馈给模型。经验法则是：快速检索定位可用 Shell，修改文件内容统一走 `apply_patch`。

## /workspace 文件系统

Agent Home 是挂载在 `/workspace` 下的持久化存储目录。`/agents/<agent_uid>` 是指向 `/workspace` 的符号链接；系统做路径安全校验时会先解析符号链接，再核验目标路径是否仍落在 Home 边界以内。标准目录布局如下：

```text
/workspace/
├── .codex/
├── SOUL.md
├── MISSION.md
├── DESIGN.md
├── ConfidentialityPolicy.md
├── installed-skills/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── AGENTS.md
    └── temp/
```

根目录下的 `SOUL.md`、`MISSION.md`、`DESIGN.md` 与 `ConfidentialityPolicy.md` 是由 [Agent Library](../agent-library/) 托管的四份长期文档：前两份定义行事准则与核心职责，`DESIGN.md` 提供制作视觉产物时遵循的设计系统，`ConfidentialityPolicy.md` 则界定 Agent 向 Brain 写入记忆时如何选择受众披露范围。`installed-skills/` 存放该 Agent 已安装的 Skill；`sessions/` 按 PostgreSQL 从 `10000` 起分配的稳定数字 ID 存放各前台会话工作区；`jobs/` 则为每个后台 Agent 任务提供彼此独立的任务工作区。

销毁容器实例或升级应用镜像后，Agent Home 中的数据完整保留；重建实例只会清空 `/var/cache/ankole` 本地缓存目录。不过请注意底层存储介质的边界：Docker 本地卷绑定在单台宿主机磁盘上；Cloudflare 容器若被强制终止，可能会丢失最近一次 R2 备份之后的写入。各运行平台的详细存储特性请参阅 [工作节点](../worker-management/)。

控制面云盘则独立于 Worker 存储消息附件、对外发布的文件、已安装 Skill 以及 Automation 脚本：Agent 可通过 `ankole-files` 读写云盘文件，通过 `ankole-pod` 经由控制面操作 Pod 页面、Base 多维表与 Applet；而后台任务工作区和 Codex 线程文件则始终保存在持久 Home 中。每轮回合启动前，Worker 会自动将本地 `installed-skills/` 目录与云盘对齐同步；后台任务运行期间则通过 `skill_view` 按需加载 Skill。

## 迭代 Python 用的 Jupyter live kernel

当手头任务需要开展交互式 Python 探索——例如需要跨步骤在内存中保留变量、逐个单元格查看和清洗 DataFrame，或是需要一个持续存活的有状态 REPL——反复跑一次性 Shell 脚本显然事倍功半。此时应使用内置的 `jupyter-live-kernel` Skill（默认启用 `default_enabled: true`）：它作为 [后台 Agent 任务](../background-jobs/)运行，底层构建在 Ankole 围绕 `hamelnb` 封装的 Unix 套接字适配器之上。由于 Python 内核在多次调用之间持续保活，Agent 可以在上一步加载大表并定义变量，紧接着在下一步直接读取分析，省去了每次重跑脚本反复加载数据的开销。

该 Skill 自身的说明给出了清晰的选型界限：简短、无状态的一次性 Python 处理直接跑普通 Shell 即可；凡是原本需要打开 Jupyter Notebook 或有状态 Python REPL 才能顺手推进的工作（如数据科学建模、DataFrame 探查、`.ipynb` 笔记本编辑、有状态接口调试），就交给 `jupyter-live-kernel`。Worker 基础镜像已预装好系统 Python、JupyterLab、`ipykernel` 及 `hamelnb` 辅助工具，因此新建的 Agent 开箱即可直接调用，无需临时安装任何依赖。

## 后台 Agent 任务使用 CodexRunner

所有后台 Agent 任务统一由 `CodexRunner` 引擎驱动。无论任务内容是深度行业调研、撰写排版报告还是跨文件重构代码仓库，决定是否走 `CodexRunner` 的唯一标准是“任务是否作为持久后台任务运行”，而非任务题材。启动时，`CodexRunner` 通过 `app-server-client.ts` 与容器内的 Codex `app-server` 通信，并为每个任务初始化专属的工作区目录与运行配置。

在 Console 界面上，控制该引擎选模的配置项显示为**后台 Agent 任务**，其底层数据库存储键名与 API 字段名均为 `coding`。

## Ankole 如何选择运行路径

日常运维中几乎无需繁琐配置，三条运行路径各司其职：

- **前台电脑工具**（`command`、`read_file` 与 `apply_patch`）随每台 Worker 开箱内置，普通对话回合可直接调用。
- **Jupyter 交互式内核**（`jupyter-live-kernel`）属于默认启用的内置 Skill，可通过 [Agent Library](../agent-library/) 统一管控（管控方式与 [浏览器自动化](../browser-automation/)完全一致），只需为不需要交互式 Python 能力的 Agent 按需关闭即可。
- **`CodexRunner`** 负责承载全部后台 Agent 任务，其所有模型请求同样统一流经 AIGateway。若希望后台任务使用不同于日常聊天的 Provider 或推理模型，只需配置该 Agent 的“后台 Agent 任务”模型档案；留空时控制面会自动回退使用该 Agent 的 `heavy` 档案。

## 下一步

- 了解承载这些工具并托管 `/workspace` 目录的运行环境，请参阅 [Agent Computer Worker](../agent-computer-worker/)。
- 了解支撑 Jupyter 等能力的 Skill 管理与启用继承模型，请参阅 [Agent Library](../agent-library/)。
- 了解“后台 Agent 任务”模型档案（内部键名 `coding`）的配置方法，请参阅 [后台 Agent 任务](../background-jobs/#选择模型-provider)。
- 了解 Worker 容器的安全信任边界与生产加固建议，请参阅 [安全加固](../security-hardening/)。
