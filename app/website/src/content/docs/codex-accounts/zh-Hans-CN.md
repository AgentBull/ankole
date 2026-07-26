---
title: Codex 账号
description: 添加 ChatGPT 订阅账号，并让指定 Agent 的后台任务使用该账号。
section: User guide
order: 41
---

后台 Agent 任务默认通过 AI Gateway 调用模型。只有明确希望任务使用 ChatGPT 订阅时，才需要添加 Codex 账号。

一个 Codex 账号可以供多个 Agent 使用。账号认证信息由控制面加密保存，不需要写入 Agent 的环境变量或聊天消息。

## 添加账号前

先在自己的电脑上登录 Codex。登录成功后，找到 Codex 生成的 `auth.json`：

- 默认位置是 `~/.codex/auth.json`。
- 如果设置过 `CODEX_HOME`，文件位于该目录下。

`auth.json` 包含账号凭据。只把它粘贴到 Ankole Console，不要发到群聊、工单或代码仓库。

## 在 Console 中添加

1. 打开 **Console → 模型提供商**。
2. 在页面下方找到“Codex 账号”，选择“新增 Codex 账号”。
3. 填写便于辨认的名称，例如“研究团队 ChatGPT”。
4. 打开 `auth.json`，复制完整内容并粘贴到对应输入框。
5. 保存。Console 会从文件内容中识别 ChatGPT Account ID。

## 让 Agent 使用该账号

1. 打开 **Console → 智能体**，选择目标 Agent。
2. 在“模型档案”中找到“后台 Agent 任务”。
3. 将运行方式改为 ChatGPT 订阅账号。
4. 选择刚添加的 Codex 账号，并按需设置模型、推理强度和 Fast Mode。
5. 保存后，新启动的后台 Agent 任务会使用这项配置。

普通聊天不会因为这项设置改用 Codex 账号。它只影响后台 Agent 任务。

## 更新或删除账号

Codex 登录信息发生变化时，重新取得完整的 `auth.json`，编辑该账号并粘贴新内容。留空保存会保留原有认证信息。

删除账号前，先检查所有 Agent 的“后台 Agent 任务”配置，并改用 AI Gateway 或其他 Codex 账号。仍有 Agent 使用时，Console 不会删除该账号。

后台任务如何创建、暂停和排障，见[后台 Agent 任务](../background-jobs/)。
