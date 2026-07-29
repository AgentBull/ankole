---
title: Git 集成
description: Ankole Agent 如何在普通对话或后台 Agent 任务中使用 git。
section: Guides
order: 303
---

Ankole Agent 通过 Worker 提供的 shell 工具运行标准 git 命令。普通对话和后台 Agent 任务都能使用这些工具。

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

在普通对话中，Agent 直接使用前台 shell 和文件工具。若 Agent 把工作交给后台任务，该任务会在自己的工作区中运行，并按要求回传结果或静默结束。具体用法见[后台 Agent 任务](../background-jobs/)。

## 需要什么

- **Git 凭证。** 在 **Console → 环境变量** 中把 SSH key 或 PAT 保存为加密变量，例如 `GIT_SSH_KEY` 或 `GIT_TOKEN`。新值从 Agent 的下一个回合开始生效。配置方法见[环境变量](../worker-env/)。
- **repo 从 worker 可达。** worker 需要能访问 git 主机的网络。私有网络里确认 worker 能到达 git 服务器。
- **按需配置后台 Agent 任务。** 默认回退配置已经可以运行任务。只有后台任务需要不同 Provider 或模型时，才单独配置“后台 Agent 任务”档案。

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

1. 在 **Console → 环境变量** 中把 PAT 保存为加密变量 `GIT_TOKEN`。
2. 创建 Agent，并配置必需的 `primary`、`light` 和 `heavy` 档案。只有需要覆盖默认回退配置时，才单独配置后台 Agent 任务。
3. 撰写 `MISSION.md`，点名 repo、审查标准、分支命名约定。
4. 在频道里问 agent："审查 `your-repo` 上最新的 PR。克隆、checkout、跑测试、报告发现。"
5. Agent 克隆仓库、切换分支、通过 `command` 运行测试并回复结果。这项工作既可以在当前对话中完成，也可以交给后台 Agent 任务。

## 本指南不是什么

它不是 git 教程——agent 用标准 git 命令。它不是 CI/CD 集成——Ankole 不跑 CI；若 repo 的 CI 是命令驱动的，agent 可通过 shell 命令触发。它不是代码审查自动化指南——agent 按其人设告诉它的方式审查代码，通过 shell 工具。

## 下一步

- shell 工具，读[代码执行](../code-execution/)。
- 后台执行，读[后台 Agent 任务](../background-jobs/)。
- 存储 Git 凭证，读[环境变量](../worker-env/)。
- 文件系统布局，读[文件管理](../file-management/)。
