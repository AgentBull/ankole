---
title: 环境变量
description: 通过 Console 为全部 Agent 或单个 Agent 配置命令行工具、MCP 服务和后台 Agent 任务所需的环境变量。
section: User guide
order: 10
---

Agent 在 Agent Computer Worker 上运行命令、调用 MCP 服务或执行后台 Agent 任务时，可能需要 API key、token、服务地址等环境变量。请在 Console 的“环境变量”中维护这些值，不要把凭据写进 Skill、Agent 文档或聊天消息。

环境变量会提供给 Agent 以及它启动的程序。这里只应保存 Agent 确实需要使用的凭据。模型提供商、身份源提供商和聊天渠道的凭据，应在各自的 Console 页面中配置。

## 先选择作用范围

| 需要谁使用 | 在哪里设置 | 生效范围 |
|---|---|---|
| 全部 Agent | **Console → 环境变量** | 默认提供给每个 Agent |
| 单个 Agent | **Console → 智能体 → 选择 Agent → 环境变量** | 只对这个 Agent 生效；同名值会覆盖全局值 |

清除 Agent 专用值后，同名的全局值会重新生效。如果没有全局值，这个 Agent 将不再收到该变量。

## 为全部 Agent 添加变量

1. 打开 **Console → 环境变量**，选择“新建变量”。
2. 填写变量名称。名称只能包含字母、数字和下划线，且不能以数字开头，例如 `MY_API_KEY`。
3. 填写变量值。API key、token、密码等敏感值应保持“加密存储”开启。
4. 按需填写备注，说明它供哪个工具或服务使用。备注不会传给 Agent。
5. 保存变量。它会从 Agent 的下一个回合开始生效。

`PATH`、`HOME`、`SHELL`、`TERM`、`LANG`、`BASH_ENV`、`ENV`、`WORKER_ID`、`RUNTIME_FABRIC_URL`、`DATABASE_URL`、`CODEX_UNSAFE_ALLOW_NO_SANDBOX` 以及以 `ANKOLE_` 开头的名称由运行环境保留，不能在这里设置。

## 只为一个 Agent 设置变量

1. 打开 **Console → 智能体**，选择目标 Agent。
2. 找到“环境变量”。
3. 添加一个新变量，或在已有变量旁选择“覆盖”。
4. 填写值并保存。

该区域会同时显示默认值、全局值和这个 Agent 的专用值。“来源”一栏表示当前生效的值来自哪里。选择“清除”可以移除 Agent 专用值，并恢复全局值或默认值。

## 看懂变量类型

| 类型 | 含义 | 可以做什么 |
|---|---|---|
| 自定义 | 由管理员在 Console 中添加 | 修改或删除 |
| 声明 | 由 Ankole 或已启用的插件提供 | 修改值，或重置为默认值 |

声明变量的名称和数据格式已经确定，因此不能改名。尚未填写且没有默认值的变量会显示为“未设置”。

## 加密、查看与轮换

新建变量时，“加密存储”默认开启。加密值在 Console 列表中始终以掩码显示，但 Agent 运行时仍会收到原始值。

编辑加密变量时，保留掩码并保存不会改变原值。要轮换凭据，直接输入新值并保存即可，不必先查看旧值。

只有确实需要核对现有值时才选择“查看”。关闭“加密存储”会把值以明文保存，Console 会要求再次确认；API key、token 和密码不应关闭加密。

## 什么时候生效

修改环境变量不会改变已经开始的执行。新值会在 Agent 的下一个回合、后续 Background Agent Job execution 和后续 Automation Job attempt 中注入。

如果 Agent 没有拿到预期的值，请依次检查：

1. 变量名称与 Skill、脚本或 `bearer_token_env_var` 声明中的名称完全一致；名称区分大小写。
2. 目标 Agent 是否存在同名专用值。专用值会覆盖全局值。
3. 变量是否显示为“未设置”。
4. 修改后是否开始了新的 Agent 回合。

MCP-backed Skill 使用 `bearer_token_env_var` 时，只填写环境变量名称，token 本身保存在这里。声明合同见 [MCP](../mcp/)。
