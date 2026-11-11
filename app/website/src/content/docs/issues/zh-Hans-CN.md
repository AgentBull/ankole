---
title: Issue
description: 在一个看板上跟进 Agent 为你做的后台工作，并验收结果。
section: User guide
order: 16
---

Issue 是你交给 Agent 的一项后台工作。它有标题、描述和一个负责执行的 Agent。每个 Issue 都有自己的对话，Agent 的回复、提问，以及它发起的 Background Agent Job 和 Workflow 都显示在这里，和 Chat 里的呈现方式一样。

## 打开看板

有 **待开始** 或 **进行中** 的事项时，Pod 侧边栏的 **主页** 标签会在 **与我共享** 上方显示 **后台 Agent 任务**。点它打开看板，看板下方是定时任务。

看板只包含你 Chat 列表里的对话。页面评论和外部 IM 里的对话不在看板上，它们的执行和定时任务要到各自的对话里查看。

看板有五列：

- **待开始**：Agent 还没有收到这项工作。
- **进行中**：Agent 正在工作，或者它发起的后台执行还在运行。
- **等你处理**：Agent 提了问题，或者在等你批准。
- **待验收**：Agent 已经停下，结果等你查看。
- **已完成**：你已经验收。

**进行中** 和 **等你处理** 反映的是 Agent 的真实状态，卡片会自己在这两列之间移动。卡片第一行是它最新的运行中执行进展到哪一步、现在是什么状态，第二行是标题，第三行是 Agent 和最近一次更新的时间。第一行的 **+** 表示这张卡片还有几个其他运行中的执行。鼠标移到卡片上会出现 **停止** 按钮。看板上方会显示正在工作的 Agent，用 **筛选** 可以只看所选 Agent 的卡片。

## 新建 Issue

想把工作交给 Agent，就在 Chat 里告诉你的个人助理或某位 AI 同事。Agent 把这项工作作为 Background Agent Job 或 Workflow 接下来以后，这个对话就成了 Issue，出现在看板上，详见下文的 **从 Chat 发起的后台工作**。

如果要直接新建 Issue，比如从脚本里新建，就向 `POST /api/v2/pod/issues` 发送 `title`、写明要做什么的 `description`，以及负责执行的 Agent 的 `agentUID`。Agent 可以是你的个人助理，也可以是一位 AI 同事。标题和描述会作为你在这个 Issue 的对话里的第一条消息发给 Agent，Agent 随即开始工作。带上 `start: false` 时，Issue 停在 **待开始**，你还可以修改描述；点 **开始**，或者把卡片拖到 **进行中**，它才开始。

想给 Issue 分类，可以在新建时用 `labels` 加上最多十个标签，之后随时用 `PATCH /api/v2/pod/issues/:id` 替换。`GET /api/v2/pod/issues` 返回的列表里带有每个 Issue 的标签。

## 让 Issue 按计划重复

新建时带上 `repeat`，Issue 就会按计划重复。`repeat` 包含两项：`expression` 是五段式 cron 表达式，比如每周一 9:00 写作 `0 9 * * 1`；`timezone` 是你所在的时区。每次运行都会把这个 Issue 的描述发给 Agent，结果发在 Issue 的对话里，所以每次运行后 Issue 都会回到 **待验收**，上一次验收过也一样。第一次运行在新建后马上开始；如果新建时带了 `start: false`，就等到第一个计划时间才运行。

下次运行的时间显示在看板下方的 **定时** 里。要暂停、恢复、删除这个计划，或者立即运行一次，可以在 Issue 的对话里告诉 Agent，也可以向 `PATCH /api/v2/pod/issues/scheduled/:id` 发送 `change`，取值为 `pause`、`resume`、`remove` 或 `run`。计划的 ID 就是 `GET /api/v2/pod/issues` 返回的 Issue 里的 `repeat.id`。

## 拆成子 Issue

子 Issue 是一个独立的 Issue，有自己的 Agent 和对话，负责一个更大的 Issue 里的一部分。新建子 Issue 时，向 `POST /api/v2/pod/issues` 发送请求，并在 `parentID` 里填父 Issue 的 ID。这个 ID 就是父 Issue 对话的 ID，而且你得能打开这个对话。在 `GET /api/v2/pod/issues` 的结果里，子 Issue 会注明它的父 Issue，父 Issue 会给出子 Issue 的总数和完成数。你验收一个子 Issue 后，父 Issue 的 Agent 会在父 Issue 的对话里收到子 Issue 的结果（以你的名义发出），接着做父 Issue 的工作。

## 交给 Squad 协作

Squad 是你的个人助理用来分担某个 Issue 的一组 AI 同事。要给 Issue 配上 Squad，新建时把个人助理设为它的 Agent，并在 `squadUIDs` 里列出这些同事的 UID。描述里会点名这些同事，助理会把工作分给他们。同事在做自己那部分时，Issue 保持在 **进行中**。在和个人助理的对话里也能这样分派工作：在消息里 @ 这些同事，助理就会把工作交给他们。

## 跟进和验收

点一张卡片，它会在看板旁边打开。**待开始** 的卡片打开的是 Issue 的标题、Agent 和描述，描述还可以修改；点 **开始**，或者把卡片拖到 **进行中**，标题和描述就会作为你在这个 Issue 的对话里的第一条消息发给 Agent。其他卡片打开的是它的后台执行详情，和在对话里展开任务看到的一样：执行计划、执行步骤和结果。你可以在这里回答执行提出的问题、追加指示，或者停掉它；点 **在对话中打开** 可以进入 Issue 的对话。

Agent 停下后，Issue 进入 **待验收**。点 **完成**，或者把卡片拖到 **已完成**，就是验收。点 **重新打开** 可以把已完成的 Issue 放回 **待验收**；还没开始就被关闭的 Issue 会带着描述回到 **待开始**。如果 Agent 在已完成的 Issue 的对话里又发起了后台工作，Issue 会自动重新打开。

## 谁能看到 Issue

Issue 对话里的人都能看到它。想让同事看到，就把同事邀请进这个对话。交给个人助理的 Issue 只有你自己能看到。

对话里只有你一个人时，你发的每条消息 Agent 都会回复。同事加入后，你的消息默认仍然发给这个 Issue 的 Agent。如果只想和同事说话、让 Agent 自己决定要不要回，把输入框下方的收件人改成 **允许主动回应的 Agent**。

## 从 Chat 发起的后台工作

你 Chat 列表里的对话，只要 Agent 在里面发起了第一个 Background Agent Job 或 Workflow，就会成为 Issue，不论是和个人助理的对话、和 AI 同事的私聊，还是群聊。不需要你做任何操作，这项工作就出现在看板上，一直留到你验收。同一个对话里再发起新的 Background Agent Job，它会重新打开。

## 定时任务

看板下方的 **定时** 列出 Agent 在你 Chat 列表的对话里维护的周期任务和待回访事项，以及下次运行的时间；暂停的任务显示 **已暂停**。点一行可以打开管理它的对话，要新建或修改定时任务，在那里告诉 Agent 即可。以你的名义运行的周期任务（比如按计划重复的 Issue），还可以用 `PATCH /api/v2/pod/issues/scheduled/:id` 暂停、恢复、立即运行或删除；这一行的 ID 可以从 `GET /api/v2/pod/issues/scheduled` 获取。
