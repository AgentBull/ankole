---
title: 一个每日简报机器人
description: 把 cron 调度、agent 的 web 工具和聊天 binding 组合起来，每天早晨发一份经过研究的简报——无需写代码，全是配置。
section: Guides
order: 301
---

本指南建立在[你的第一个 Lark 机器人](../lark-first-bot/)（或任何可用的聊天 binding）之上，加上一样能把被动机器人变成主动同事的东西：调度。agent 每天早晨自己醒来，研究你关心的话题，并把简报发到频道里——全程无人值守。

一句话讲完流程：**选一个频道 → 设 agent 的简报任务 → 调度它 → 验证首次触发 → 让它记忆。**

不涉及代码。那些部件——agent 循环、`web_search`、`web_fetch`、cron 调度、binding——已经存在。本指南把它们为一个场景接起来。

## 你要建什么

一个每天触发一次的定时回合：

1. **你时区的 09:00**——cron 调度在 agent 的 session 上触发一次 `scheduled_task` 回合。
2. **agent 跑它的循环**——读它的 `MISSION`/`SOUL` 人设和你设在调度上的 `task`。
3. **`web_search` 和 `web_fetch`** 抓取人设所点名话题的当前来源。
4. **agent 综合**出一份短简报。
5. **投递**让简报落到绑定的频道——Lark、Slack、钉钉或 Microsoft 365——按 binding 的 reply mode。

## 前置条件

- 一套可用的 Ankole 部署，至少有一个 agent 和一个聊天 binding。还没有的话先做[你的第一个 Lark 机器人](../lark-first-bot/)。
- agent 的 `web_search` profile 已绑到提供 web 搜索的 provider（见 [Provider 与模型](../providers-and-models/)）。没有它，agent 没有研究工具。
- 一个 agent 已绑定、并能发帖的频道。

## 第 1 步：给 agent 简报使命

调度带着一个简短的 `task`，但简报的*风格*住在 agent 的人设里。撰写一份 `MISSION.md`，点名话题和格式：

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/library-documents/mission \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "content": "你为团队产出每日简报。\n\n话题：我们依赖的库的发布、影响我们技术栈的安全公告、两个指定竞品的值得注意的动向。\n\n格式：三节，每话题一节。每节一段，最多三个链接。不废话，不开场白。" }'
```

人设是放话题和格式的地方；调度只说*何时*跑、*什么*（短句）。这样分开，让你能调风格而不动调度。

## 第 2 步：绑定 web 搜索 profile

确认 agent 已绑 `web_search` model profile，指向提供 web 搜索的 provider。没有它，agent 会跑循环，但凭记忆产简报而非当前来源——这违背每日简报的本意。槽位见 [Provider 与模型](../providers-and-models/)。

## 第 3 步：创建 cron 调度

在 agent 的 session 上创建调度，指向简报应当投递的 binding：

```bash
curl -X POST https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/cron-schedules \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "binding_name": "main",
    "name": "morning-briefing",
    "schedule": { "cron": "0 9 * * *", "kind": "cron" },
    "timezone": "Asia/Shanghai",
    "payload": { "task": "产出今天的简报。" }
  }'
```

两个字段容易弄错：

- **`timezone`**——cron 表达式在这个时区求值。没有时区的 09:00 调度有歧义；显式设它，让简报落在*你团队所在地*的 09:00，而不是服务器碰巧所在的地方。
- **`binding_name`**——简报通过这个 binding 投递，它决定频道和 reply mode。用指向你团队所读频道的那个 binding。

完整字段集（含暂停、恢复、手动运行）见[调度](../schedules/)。

## 第 4 步：用一次手动运行验证

别等到 09:00 才知道调度是否管用。手动触发：

```bash
curl -X POST https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/cron-schedules/<cron_schedule_id>/runs \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

手动运行产生一次具体触发事件，和自然触发一样被记录在运行列表。在绑定的频道观察简报；若没出现，检查运行和 worker 日志。这一阶段常见失败：

- **没发简报**——binding 被禁用，或 agent 的 `web_search` profile 未绑。调度触发了，但回合无处投递或无搜索工具。
- **凭记忆而非当前来源的简报**——`web_search` 解析到了一个其实不提供搜索的 provider；检查 profile 的选择符。
- **时间错的简报**——`timezone` 设错；手动运行看不出这一点，所以对照你团队所在地再核一遍。

## 第 5 步：让它跨天记忆

一个每日简报，在 agent 注意到自昨天以来发生了什么变化时更有用。两个可选动作：

- **Brain 策展知识**——通过 [Brain](../brain/) 界面，策展几行持久事实（哪些竞品要紧、哪些库在我们栈里）。召回在回合中读取这些，让简报始终锚定在你真正关心的事上。
- **session 连续性**——调度在某一个 session 上触发，所以 agent 的回合自然能访问该 session 的近期上下文。如果你想每天的简报都引用前一天的那份，把它们留在同一个 session，而不是重置。

策展知识是两者中杠杆更大的那个：它经过复核、持久、按 agent 限定范围，而 session 记忆是临时的。

## 日常运维

- **假日暂停**——`POST .../cron-schedules/:id/pause`。状态移到 `paused`；不发简报。
- **恢复**——`POST .../cron-schedules/:id/resume`。重新装上规划器。
- **改时间**——`PATCH` 调度的 `schedule` 字段；规划器重新装上。
- **现在跑一次**——`POST .../cron-schedules/:id/runs`，跳出 cron 节奏。

## 变体

- **一天多份简报**——用更频繁 cron 表达式的调度（每六小时、一天两次）。`task` 保持一致；人设决定格式。
- **每份简报不同频道**——同一 agent 两个调度，各自不同 `binding_name`。
- **简报加按需回答**——保留调度，让团队白天 @ 同一个 agent。一个 agent，两种唤醒方式。

## 本指南不是什么

它不是代码教程——没有要写的脚本，没有在你已有部署之外要构建的东西。它也不是任何 LLM 第一次就产出好简报的承诺；人设和策展知识是你在几天里、看着 agent 实际发出的内容调质量的地方。

## 下一步

- 调度界面，读[调度](../schedules/)。
- 简报可调用的记忆，读 [Brain](../brain/)。
- 简报投递所走的 binding，读 [Signal binding](../signal-bindings/) 和你的 adapter 专页。
