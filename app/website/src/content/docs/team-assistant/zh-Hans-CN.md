---
title: 一个观察频道的团队助理
description: 把一个只回应 @ 的机器人变成团队助理——让它观察频道、把 directory 成员同步进 AuthZ，并决定何时开口、何时安静。
section: Guides
order: 306
---

首机器人指南都止于"只在被 @ 时醒来"的 agent。本指南走下一步：一个**观察**共享频道的 agent——读大家在说什么、注意谁在里面、并自己判断何时帮忙。这是客户成功助理、on-call 帮手、或团队知识管家的形态。

一句话讲完流程：**从一个可用的只 @ 回应机器人开始 → 放宽群消息策略 → 把 directory 成员同步进 AuthZ → 在人设里设定助理的判断 → 通过观察来调阈值。**

与[你的第一个 Lark 机器人](../lark-first-bot/)的区别是一个字段加一份判断。字段放宽 agent 看到什么；判断写进人设，决定 agent 对所见做什么。

## 你要建什么

一个长这样的团队助理：

1. **频道里的每条消息**变成 agent 可见的镜像条目。
2. **Directory 成员**同步进 AuthZ group，于是 agent 知道团队里都有谁、他们被允许做什么。
3. **agent 读每条消息**，并按其人设，决定是现在回复、记录以备后用、还是保持安静。
4. **人可以 @ 它**，在 agent 判断过于安静时强制回复。

杠杆不是"让 agent 变话痨"的开关。它是一个策略加一份人设——人设告诉 agent，话痨什么时候是错的。

## 前置条件

- 一套可用的 Ankole 部署，有一个 agent 和一个聊天 binding，见[你的第一个 Lark 机器人](../lark-first-bot/)（或 Slack/钉钉/Teams 等价物）。
- agent 绑到一个**群**频道，不是私信——观察只在有对话发生的地方才有意义。
- 同一平台配好了 identity provider（Lark、Entra ID、Google Workspace 或 Slack），directory 同步才有来源。

## 第 1 步：放宽群消息策略

binding 的 `unaddressed_group_message_policy` 有三个值，这就是整个旋钮：

| 策略 | agent 对非 @ 群消息做什么 |
|---|---|
| `ignore` | 连镜像都不做——什么都看不到 |
| `record_only`*（默认）* | 镜像消息但不唤醒；agent 以后能召回，但现在不据此行动 |
| `may_intervene` | 镜像消息**并**产生一个 `may_intervene` 事件，于是 agent 醒来，可以决定是否开口 |

把 binding 从 `addressed_only` 改到 `may_intervene`：

```bash
curl -X PATCH https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "unaddressed_group_message_policy": "may_intervene" }'
```

`may_intervene` **不**意味着"什么都回"。它意味着"醒来并决定"。agent 是否真回复是人设的判断，所以第 3 步和这一步同样要紧。在 Lark 和钉钉上，放宽策略还需要平台侧读取非 @ 群消息的权限（Lark 上的 `im:message.group_msg`）——在应用配置里授予。

`record_only` 作为中间地带值得知道：让 agent 在不插话的情况下建立对频道的记忆。当你想让助理观察但安静（除非被明确要求）时，用它。

## 第 2 步：把 directory 成员同步进 AuthZ

一个不知道团队里有谁的团队助理是在猜。把平台的 directory 同步进 AuthZ group，让 agent 的权限范围反映真实团队。

通过 identity-provider 界面配置 directory 同步——和你为管理员登录配的是同一个。Lark 和钉钉拉 IM 群和组织结构；Entra ID 和 Google Workspace 拉 directory group；Slack 拉 workspace 成员。触发一次同步：

```bash
curl -X POST https://ankole.example.com/api/v1/identity-providers/<provider_id>/sync-runs \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

同步之后，平台的 group 作为 Ankole AuthZ group 存在，你可以通过 [Principal 与 AuthZ](../principal-authz/) 向它们授予权限。助理作为一个 Principal，可以被授予这些 group 范围内的能力——或不被授予。这正是阻止观察型助理越界的杠杆：它看得到频道，但它被允许*做*什么仍由 AuthZ 隔离。

## 第 3 步：把助理的判断写进人设

策略让 agent 醒来；人设决定它醒来时做什么。团队助理在此成或败。撰写一份 `MISSION.md`，点名判断：

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/library-documents/mission \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "content": "你是这个频道的团队助理。\n\n开口条件：有人问了一个问题、几分钟内没人答；有人问一个你知道或能查到的事实；正在做一个决定、而你有相关上下文。\n\n安静条件：频道只是闲聊；已经有人在答；你的回复会是噪声。不确定时倾向安静。人可以 @ 你强制回复。" }'
```

判断是针对你的团队的——"噪声"意味着什么、"相关上下文"意味着什么、"几分钟"是多久。写真实答案，不是通用建议。人设是团队助理被调谐的地方，在几天里、看着 agent 实际做了什么。

## 第 4 步：观察阈值并调谐

让助理跑一天。两种失败模式告诉你往哪调：

- **太吵**——回复了本该放过的东西。收紧人设（更多"安静正确"的情况），或把策略降回 `record_only`、重写判断。吵闹的助理比安静的助理更快侵蚀信任。
- **太静**——该开口时也不开。放宽人设，或确认 binding 确实是 `may_intervene`、平台侧群消息权限已授予。

正确答案很少是"总开"或"总静"。它是人设编码的判断，你通过观察来打磨。

## 第 5 步：让它跨天记忆

一个记得团队在意什么的团队助理会变好。两个动作，都可选：

- **Brain 策展知识**——通过 [Brain](../brain/) 界面，策展持久事实（谁拥有什么、哪些决定已定、哪些问题常被问起）。召回在回合中读取这些，于是助理的回答锚定在团队已决定的事上，而非模型猜的。
- **`record_only` 作为记忆底**——即使策略是 `may_intervene`，`record_only` 做的镜像仍在发生。agent 能访问频道近期上下文，这是它注意到"昨天有人问过这个"的依据。

## 日常运维

- **让它静而不禁用**——`PATCH` 策略回 `record_only`。agent 继续观察，但停止决定开口。
- **限定它能做什么**——即使 `may_intervene`，agent 只做 AuthZ 授予允许的事。助理有不该在频道里用的能力时，收紧授予。
- **轮换人设**——判断是一份文档，不是代码。编辑它，观察一天，再编辑。

## 本指南不是什么

它不是让 agent 想说话就说话的许可。`may_intervene` 是让 agent 醒来的策略；人设是阻止它变成噪声的东西。它也不是 AuthZ 的替代——agent 看得到频道，但它被允许做什么仍由 Principal 授予隔离。团队助理模式是策略 + 人设 + 权限，一起设。

## 下一步

- policy 字段和 binding 模型，读 [Signal binding](../signal-bindings/)。
- 隔离助理能做什么的权限模型，读 [Principal 与 AuthZ](../principal-authz/)。
- 它可调用的记忆，读 [Brain](../brain/)。
