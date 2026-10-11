---
title: 环境变量
description: 通过 Console 为全部 Agent 或单个 Agent 配置命令行工具、MCP 服务和后台 Agent 任务所需的环境变量。
section: User guide
order: 10
---

Agent 在 Agent Computer Worker 上运行命令、调用 MCP 服务或执行后台 Agent 任务时，可能需要 API key、token、服务地址等环境变量。请在 Console 的“环境变量”中维护这些值，不要把凭据写进 Skill、Agent 文档或聊天消息。

环境变量会提供给 Agent 以及它启动的程序。Agent 运行的每条命令都从一个包含这些值的全新环境开始，不会继承 Worker 进程的环境。这里只应保存 Agent 确实需要使用的凭据。模型提供商、身份源提供商和聊天渠道的凭据，应在各自的 Console 页面中配置。

## 先选择作用范围

| 需要谁使用 | 在哪里设置 | 生效范围 |
|---|---|---|
| 整个站点的 Agent | **Console → 环境变量 → 新建站点变量** | 站点默认值 |
| 一个租户的 Agent | **Console → 选择租户 → 环境变量 → 新建租户变量** | 在该租户内覆盖站点值 |
| 单个 Agent | **Console → 智能体 → 选择 Agent → 环境变量** | 为该 Agent 覆盖租户值与站点值 |

系统依次读取 Agent 覆盖、租户值和站点默认值。清除覆盖后使用下一级可用值；各级都没有值时，不提供该变量。

## 添加站点或租户变量

1. 打开 **Console → 环境变量**，选择租户，再按需要选择“新建站点变量”或“新建租户变量”。
2. 填写变量名称。名称只能包含字母、数字和下划线，且不能以数字开头，例如 `MY_API_KEY`。
3. 填写变量值。API key、token、密码等敏感值应保持“加密存储”开启。
4. 按需填写备注，说明它供哪个工具或服务使用。备注不会传给 Agent。
5. 保存变量。

`PATH`、`HOME`、`SHELL`、`TERM`、`LANG`、`BASH_ENV`、`ENV`、`WORKER_ID`、`DATABASE_URL`、`CODEX_UNSAFE_ALLOW_NO_SANDBOX` 以及以 `ANKOLE_` 开头的名称由运行环境保留，不能在这里设置。

## 只为一个 Agent 设置变量

1. 打开 **Console → 智能体**，选择目标 Agent。
2. 找到“环境变量”。
3. 添加一个新变量，或在已有变量旁选择“覆盖”。
4. 填写值并保存。

该区域显示站点值、租户值和 Agent 值。“来源”列说明当前生效值来自哪里。“清除”只移除 Agent 覆盖，随后可以使用租户值或站点值。

## 看懂变量类型

WorkerEnv 条目均为运维者添加的自定义值。Ankole 与插件不会通过 WorkerEnv 导出 AppConfigure 键。运行环境保留的变量和 binding 凭据由各自所属领域维护。

## 加密、查看与轮换

新建变量时，“加密存储”默认开启。加密值在 Console 列表中始终以掩码显示，但 Agent 运行时仍会收到原始值。

编辑加密变量时，保留掩码并保存不会改变原值。要轮换凭据，直接输入新值并保存即可，不必先查看旧值。

只有确实需要核对现有值时才选择“查看”。关闭“加密存储”会把值以明文保存，Console 会要求再次确认；API key、token 和密码不应关闭加密。

## 什么时候生效

修改对后续 Worker 工作生效。已经捕获环境的执行或工作区继续使用原值。主模型推理运行在控制面，不把 WorkerEnv 当作控制面进程环境。

如果 Agent 没有拿到预期的值，请依次检查：

1. 名称与 Skill、脚本或 `bearer_token_env_var` 声明完全一致；名称区分大小写。
2. 先检查 Agent 与租户覆盖，再检查站点默认值。
3. 确认至少一个作用域保存了值。
4. 修改后启动新的 Worker 工作；已有工作区保持创建时的环境。

MCP-backed Skill 使用 `bearer_token_env_var` 时，只填写环境变量名称，token 本身保存在这里。声明合同见 [MCP](../mcp/)。
