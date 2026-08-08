---
title: ChatGPT 订阅 Provider
description: 通过设备码登录把 ChatGPT 订阅接入 AIGateway，并用凭据池管理多个账号。
section: User guide
order: 41
---

ChatGPT 订阅是普通的 AIGateway Provider。任何模型档案都可以指向它，包括普通对话和后台 Agent 任务。模型档案选择 Provider 行和模型，不选择行内的某一个账号。

Provider 行拥有一个凭据池。控制面加密保存每个账号的 token，负责刷新 OAuth token，并为每次请求选择可用的池成员。Agent Computer 只会收到 AIGateway 地址和 AIGateway Key，不会收到 ChatGPT refresh token。

## 创建 Provider

1. 打开 **Console → 模型提供商**。
2. 新增 Provider，并选择 **ChatGPT 订阅** 类型。
3. 填写稳定的 Provider ID，例如 `chatgpt-main`。
4. 保存 Provider。

默认端点和身份请求头与 Codex 协议一致。只有部署有明确要求时，才修改高级设置中的端点或请求头。

## 通过设备码添加账号

1. 打开刚创建的 ChatGPT 订阅 Provider。
2. 选择“添加 ChatGPT 账号”。
3. 打开 Console 显示的验证链接，输入一次性验证码。
4. 等待 Console 完成登录并添加池成员。
5. 要增加备用账号时，在同一个 Provider 中重复以上流程。

Console 会优先使用官方设备码登录。若该入口不可用，Console 会显示浏览器登录链接，并要求粘贴完整的回调 URL。Enterprise 运维者也可以直接添加受信任的 access token 和对应的 ChatGPT Account ID。

## 配置凭据池

每个成员显示 label、priority、source、健康状态、请求计数、限额信息，以及模型或图像用量。页面永远不会回显 secret token。

可以选择以下策略。Console 会翻译显示名称，API 值和存储值保持不变：

| Console 显示 | API 值 | 行为 |
| --- | --- | --- |
| 优先使用首个 | `fill_first` | 持续使用第一个健康成员，直到它不可用。 |
| 轮询 | `round_robin` | 每次选择后轮转。 |
| 最少使用 | `least_used` | 选择请求计数最小的成员。 |
| 随机 | `random` | 随机选择一个健康成员。 |

`exhausted` 成员会在冷却结束后自动回池。`dead` 成员必须重新登录或替换凭据。也可以禁用或删除成员。只修改 label 不会清除 `dead` 状态。

## 分配给 Agent

1. 打开 **Console → 智能体**，选择目标 Agent。
2. 打开需要配置的模型档案。持久任务使用“后台 Agent 任务”，普通模型回合使用对应的其他档案。
3. 选择 ChatGPT 订阅 Provider 和账号有权使用的模型。
4. 按需设置推理强度和 Fast Mode。
5. 保存模型档案。

所有调用仍然通过 AIGateway。网关会尽量让同一个有状态 thread 使用同一账号，在可重试的 Provider 失败后轮换池成员，但不会切换到另一个 Provider。若所有成员都不可用，交互式调用会返回带下一次恢复时间的限额错误；后台 Agent 任务会回到 `queued`，等最早可恢复的池成员。

后台任务如何创建、控制和排障，见 [后台 Agent 任务](../background-jobs/)。
