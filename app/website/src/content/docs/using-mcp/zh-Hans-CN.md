---
title: 使用 MCP-backed Skill
description: 已启用的 Skill 如何通过 mcporter 把 Agent 或 Automation 脚本路由到 MCP server。
section: Developer guide
order: 123
---

Ankole 把 MCP 放在 Skill 背后使用。Skill 负责领域路由和结果规则；固定版本的 mcporter CLI 只负责发现并调用 Skill 已选中的那个工具。

对于 Agent 自己的领域集成，不要在 Agent 上直接注册 MCP server。启用声明该依赖的 Skill；禁用 Skill 后，依赖会从下一次执行中消失。

## Main Agent 与 Background Agent Job

向 Agent 提出业务数据需求，不要让用户选择 MCP 工具名。Agent 读取匹配的 Skill，先选择一个工具，只在必要时检查这个工具的当前 schema，然后用 stdin JSON 调用 mcporter。

Main Agent 使用 command tool；Background Agent Job 使用 Codex terminal。两条路径都不会把完整 MCP catalog 暴露成模型原生工具。

## Automation Job

Automation Job 不读取 Skill 指引。编写 `main.ts` 的 Agent 必须把已选工具、参数、边界和结果检查写进脚本。

每个 Automation attempt 都会通过 `MCPORTER_CONFIG` 获得当前 enabled Skills 的依赖，并获得最新 Agent WorkerEnv。脚本使用 `Bun.spawn` 调 mcporter，把 JSON 写入 stdin，检查 exit code，再解析 stdout。不要创建 `~/.mcporter/mcporter.json`。

## 凭据

Skill 只保存 `MCP_HTTP_TOKEN` 这样的凭据变量名。变量值在 Console 的[环境变量](../worker-env/)中配置。生成配置只包含变量名，不包含值。

变量缺失时调用会失败。不要把 token 粘贴进聊天、Skill、脚本、参数文件或 shell command。

## 失败与结果边界

声明无效或同名 server 冲突时，执行会在模型命令或 Automation 脚本启动前失败。transport、protocol、argument 或 server 错误会让 mcporter 以非零状态退出。

command 与 Automation 日志都有上限。必须遵守 Skill 的分页、时效、warning 和 partial-result 规则；process 成功退出不等于业务结果完整。

## 参考

- [MCP server 参考](../mcp/)定义声明和运行语义。
- [编写 Skill](../writing-a-skill/)说明作者契约。
- [环境变量](../worker-env/)定义凭据存储。
