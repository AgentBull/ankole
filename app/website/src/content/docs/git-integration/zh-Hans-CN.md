---
title: Git 集成
description: Ankole agent 如何与 git 工作——shell 工具、工作空间布局、code-heavy 工作的 CodexRunner 路径。
section: Guides
order: 325
---

做代码工作的 Ankole agent 通过 worker 提供的 shell 工具与 git 交互——bubblewrap 下的 `command`、文件读取与 patch、code-heavy 回合的 CodexRunner。本指南是那个集成的实际形态：agent 能做什么、工作空间什么样、如何为 git 工作设置 agent。

先把决定性的性质说清楚：agent 在 **worker 的 sandbox 内**运行 git，针对 `/agents/<key>/` 文件系统。它没有特殊的 git 集成层——它用与做其他事相同的 shell 工具，文件系统就是工作空间。`design-md` skill 和人设承载约定；工具承载执行。

## agent 能用 git 做什么

通过 `command` 工具，agent 运行 sandbox 允许的任何 git 命令：

```bash
git clone https://github.com/your-org/your-repo.git
git checkout -b feature/agent-fix
git add -A && git commit -m "Fix: resolve the null-pointer case"
git push origin feature/agent-fix
```

agent 克隆进工作空间（`/agents/<key>/jobs/<job-id>/` 或 `sessions/<id>/` 下），通过文件编辑和 patch 工具改代码、提交、推送——全通过 shell、全在 bubblewrap 约束下。

code-heavy 回合走 CodexRunner 路径（见 [Codex 集成](../codex-integration/)）提供结构化代码工作的 Codex app-server。更轻的编辑用 `patch` 和 `apply-patch` 工具直接改文件。

## 需要什么

- **WorkerEnv 里的 git 凭证。** 把 SSH key 或 PAT 存为 WorkerEnv secret（`PUT /worker-envs/GIT_SSH_KEY` 或 `GIT_TOKEN`）。worker 在下个回合捡起它。见 [WorkerEnv 管理](../worker-env-management/)。
- **repo 从 worker 可达。** worker 需要能访问 git 主机的网络。私有网络里确认 worker 能到达 git 服务器。
- **绑定 `coding` model profile。** code-heavy 工作受益于为代码调优的模型；agent 做大量编码时绑 `coding` 槽。

## 工作空间

git repo 克隆进按 session 或按任务的工作空间：

```text
/agents/<agent-key>/
└── jobs/<job-id>/
    └── your-repo/       # 克隆到这里
        ├── .git/
        └── ...           # 工作树
```

工作空间在 Agent Home 卷上持久——worker 重启不丢克隆。布局见[文件管理](../file-management/)。

## 一个完整示例

设置一个审查 PR 的编码 agent：

1. 存 git 凭证：`PUT /worker-envs/GIT_TOKEN`，带 PAT。
2. 创建 agent，绑 `primary`、`light`、`heavy` 和 `coding` profile。
3. 撰写 `MISSION.md`，点名 repo、审查标准、分支命名约定。
4. 在频道里问 agent："审查 `your-repo` 上最新的 PR。克隆、checkout、跑测试、报告发现。"
5. agent 克隆、checkout、通过 `command` 跑测试、回报。

## 本指南不是什么

它不是 git 教程——agent 用标准 git 命令。它不是 CI/CD 集成——Ankole 不跑 CI；若 repo 的 CI 是命令驱动的，agent 可通过 shell 命令触发。它不是代码审查自动化指南——agent 按其人设告诉它的方式审查代码，通过 shell 工具。

## 下一步

- shell 工具，读[代码执行](../code-execution/)。
- CodexRunner 路径，读 [Codex 集成](../codex-integration/)。
- 存储 git 凭证，读 [WorkerEnv 管理](../worker-env-management/)。
- 文件系统布局，读[文件管理](../file-management/)。
