---
title: 使用 MCP-backed Skill
description: 已启用的 Skill 如何通过 mcporter 将主对话 Agent、后台任务或自动化脚本路由至外部 MCP 服务。
section: Developer guide
order: 123
---

在 Ankole 中，外部 MCP 服务统一封装在 Skill 背后调用：由 Skill 定义领域路由逻辑与结果处理规范，再交由固定版本的 `mcporter` 命令行工具按需查询并调用该 Skill 选定的单个具体工具。

为 Agent 接入外部业务系统时，请勿尝试直接在 Agent 层面全局注册 MCP 服务——正确做法是启用声明了对应 MCP 依赖的 Skill；日后一旦停用该 Skill，相关 MCP 依赖也会从下一轮执行起自动移除。

## Main Agent 与 Background Agent Job

日常对话中，用户只需自然描述业务数据需求，无需手动点名底层 MCP 工具名称。收到请求后，Agent 会先读取匹配的 Skill 指引，从中选定目标工具，仅在确有必要时查询该工具的最新参数 Schema，最后通过标准输入（stdin）传入 JSON 参数调用 `mcporter`。

在调用通道上，主对话 Agent 通过 `command` 终端工具运行命令，后台 Agent 任务则通过 Codex 终端调用；无论走哪条路径，系统都不会将庞大的原始 MCP 工具目录直接注册为模型原生工具。

## Automation Job

自动化任务（Automation Job）在运行时不经过模型推理，也不会读取 `SKILL.md` 文本指引；因此负责编写 `main.ts` 的 Agent 必须事先将选定的目标工具、调用参数、超时边界与返回结果校验逻辑明确固化在 TypeScript 脚本代码中。

每次启动自动化任务尝试时，运行环境都会通过 `MCPORTER_CONFIG` 自动注入当前全部已启用 Skill 的 MCP 依赖配置，并加载该 Agent 最新的 Worker 环境变量。脚本内部直接通过 `Bun.spawn` 拉起 `mcporter`，将参数 JSON 写入子进程标准输入，严格检查进程退出码后再解析标准输出。切勿在脚本中自行创建或写入 `~/.mcporter/mcporter.json`。

## 凭据

Skill 配置文件中仅记录环境变量名称（例如 `MCP_HTTP_TOKEN`），真正的密钥明文统一保存在 Console 的 [环境变量](../worker-env/) 页面中；运行时动态生成的临时配置文件同样只包含变量名引用，绝不落盘明文密钥。

若缺少所需的环境变量，`mcporter` 调用会直接报错失败。使用过程中严禁将访问令牌明文粘贴进聊天窗口、`SKILL.md`、脚本源码、参数文件或 Shell 命令行字符串中。

## 失败与结果边界

若 MCP 依赖声明格式有误，或多个已启用 Skill 之间出现了同名但参数不一致的服务声明冲突，执行会在启动模型命令或自动化脚本之前直接拦截失败；而在调用阶段遇到的网络传输故障、协议不兼容、入参校验失败或远端服务端报错，则会令 `mcporter` 以非零状态码退出。

需要注意，无论是 `command` 工具输出还是自动化任务日志都设有体积截断上限。调用方必须严格遵守对应 Skill 所规定的分页拉取、数据时效核对、告警提示与部分结果（partial-result）处理规范——子进程以状态码 `0` 正常退出仅代表通信成功，并不等同于业务数据已完整无误。

## 参考

- 关于依赖声明语法与运行时隔离机制，请参阅 [MCP server 参考](../mcp/)。
- 关于编写自定义 Skill 的完整规范，请参阅 [编写 Skill](../writing-a-skill/)。
- 关于安全托管访问令牌的操作步骤，请参阅 [环境变量](../worker-env/)。
