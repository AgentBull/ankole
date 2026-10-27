---
title: Git 集成
description: Ankole Agent 如何在普通对话或后台 Agent 任务中使用 Git 操作代码仓库。
section: Guides
order: 303
---

无论是在日常对话还是后台 Agent 任务中，Ankole Agent 都可以调用 Worker 提供的 Shell 工具运行标准 Git 命令。

Agent 在专属 Worker 上通过常规 Shell 与文件工具操作持久化 `/workspace` 目录中的 Git 仓库；即使销毁容器实例或更换镜像，仓库数据依然保留。

## agent 能用 git 做什么

借助 `command` 工具，Agent 会以 Worker 运行用户的身份执行 Git 命令：

```bash
git clone https://github.com/your-org/your-repo.git
git checkout -b feature/agent-fix
git add -A && git commit -m "Fix: resolve the null-pointer case"
git push origin feature/agent-fix
```

Agent 先将代码仓库克隆到工作空间（位于 `/workspace/jobs/<job-id>/` 或 `sessions/<id>/` 下），随后使用文件编辑与补丁工具修改代码，并通过 Shell 完成提交和推送，全程均以 Worker 用户身份运行。

在普通对话中，Agent 直接在前台调用 Shell 和文件工具；若将工作委派给后台任务，任务会在独立工作区中运行，结束后按约定回传结果或静默退出。详见 [后台 Agent 任务](../background-jobs/)。

## 需要什么

- **配置 Git 凭证。** 在 **Console → 环境变量** 中，将 SSH 密钥或个人访问令牌（PAT）保存为加密变量（如 `GIT_SSH_KEY` 或 `GIT_TOKEN`），新值将在 Agent 的下一回合生效。配置方法见 [环境变量](../worker-env/)。
- **打通 Worker 到代码仓库的网络。** Worker 必须能够连接目标 Git 主机；若部署在私有网络中，请先确认 Worker 到 Git 服务器的路由可达。采用 Docker Compose 部署时，Worker 容器位于 `ankole_workers` 网络中，可同时访问控制面和公网，因此能够直接连接公网上的 Git 主机。采用 Helm Chart 部署并开启 `networkPolicy.enabled` 时，Worker Pod 可访问控制面、DNS 和公网地址；但若 Git 服务器位于私有网段，且该网段仍列在 `networkPolicy.workerDeniedCIDRs` 中，连接就会被拦截。
- **按需配置后台 Agent 任务。** 默认回退配置已足以运行后台任务；仅当后台任务需要改用其他提供商或模型时，才需单独配置“后台 Agent 任务”档案。

## 工作空间

Git 仓库会克隆到按 Session 或按任务隔离的工作空间目录中：

```text
/workspace/
└── jobs/<job-id>/
    └── your-repo/       # 克隆到这里
        ├── .git/
        └── ...           # 工作树
```

替换 Worker 或升级镜像后，`/workspace` 中的仓库数据仍会保留。不过，若要防范底层存储故障导致的数据丢失，仍需及时推送至远程仓库或另行备份。如需将产物共享到 [Agent 云盘](../file-management/)，可运行 `ankole-files put` 发布文件。

## 一个完整示例

下面以配置一个负责审查 PR 的研发 Agent 为例：

1. 在 **Console → 环境变量** 中，将 PAT 保存为加密变量 `GIT_TOKEN`。
2. 创建 Agent，配置必需的 `primary`、`light` 和 `heavy` 模型档案；仅当需要覆盖默认回退配置时，再单独配置后台 Agent 任务。
3. 编写 `MISSION.md`，写明目标代码仓库、审查标准与分支命名约定。
4. 在频道中向 Agent 发送指令：“审查 `your-repo` 上最新的 PR：克隆仓库、检出分支、运行测试，并汇报发现的问题。”
5. 收到指令后，Agent 会克隆仓库、切换分支、通过 `command` 工具运行测试并回复审查结果。整套流程既可在当前对话中直接完成，也可委派给后台 Agent 任务执行。

## 本指南不是什么

- **不是 Git 教程**：Agent 直接运行标准 Git 命令，无需特殊语法。
- **不是内置 CI/CD 服务**：Ankole 本身不托管 CI 流水线；但如果目标仓库支持通过命令行触发 CI，Agent 可在 Shell 中直接调用。
- **不是固定的代码审查流水线**：Agent 如何审查代码完全取决于其人设与使命文件定义，底层统一通过 Shell 工具执行。

## 下一步

- 了解 Shell 工具的用法，请参阅 [代码执行](../code-execution/)。
- 了解后台执行机制，请参阅 [后台 Agent 任务](../background-jobs/)。
- 了解如何安全存储 Git 凭证，请参阅 [环境变量](../worker-env/)。
- 了解如何使用 Agent 云盘，请参阅 [文件管理](../file-management/)。
