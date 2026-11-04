---
title: 使用 MCP-backed Skill
description: 配置外部连接，在 Agent Skill 或 Applet Action 中使用 MCP 工具。
section: Developer guide
order: 123
---

为 Agent 启用对应 Skill，并描述业务目标。Agent 阅读 Skill、选择工具，再通过 Shell 调用 MCPorter。主对话和后台 Agent 任务使用同一个控制面网关，都不会把上游完整工具目录注册为模型原生工具。

## 配置访问

GitHub、飞书和 Linear 等内置工具集在 Pod「外部连接」页面配置应用。需要个人名义的操作由成员连接自己的账户。有多个连接时明确选择；缺少授权时，错误会提供链接，成员完成授权后重试。

远程 HTTP Skill 的 `bearer_token_env_var` 引用「环境变量」中配置的值。控制面网关读取并注入上游请求，该密钥不会进入 Worker 快照。本地 `stdio` 服务仍在 Worker 内按声明的命令运行。

## 在 Applet 中调用

在 Applet 服务端模块发布 Action，处理函数调用 `AnkoleRuntime.mcp.call(tool, arguments, {server, connection})`；团队操作使用 `AnkoleRuntime.admin.mcp`。Function Runtime 宿主管理调用凭据。在「自动化」面板创建任务、连接来源并查看运行记录。Applet Action 不启动 Worker 脚本，也不继承 Agent 已启用的 Skill。

## 处理失败

遵守每个工具声明的输入和输出契约。Shell 调用通过标准输入传递 JSON，并明确设置超时，示例见 [MCP 参考](../mcp/)。传输成功后仍需检查业务错误、分页和部分结果。部分写入错误会标明已完成的资源，应补做剩余操作；结果不确定的写入应先检查上游状态，再决定是否重试。

继续阅读[自动化任务](../automation-jobs/)和[环境变量](../worker-env/)。
