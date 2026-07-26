---
title: Brain
description: Ankole 实例的长期记忆，包括整理后的知识、原始聊天召回、Dreaming 和人工审核；PostgreSQL 记录是事实，Markdown 是投影。
section: Developer guide
order: 104
---

Brain 是一个有归属主体的长期记忆。它同时持有三样东西：agent 据以工作的策展知识、回溯到源聊天里真正说过什么的召回路径，以及把原始历史转成已索引剧集与待定知识梦境过程。在待定知识成为事实之前，由人复核。本页对照 `Ankole.Brain` 里的真实代码，画出这套模型。

先把决定性的性质说清楚：结构化知识是持久事实，Markdown 是它的投影——而不是反过来。Brain 协调证据、策展、当前知识和人工复核。聊天证据仍归 SignalsGateway；Brain 拥有留存 source 的字节、策展知识、dreaming 状态和恢复记录。

## scope：谁能看到什么

Brain 的每一次读写都流经一个 `Brain.Scope`，而这个 scope 只从 AIGateway 会话上的声明推导出来——具体是 `conversation.metadata["brain"]`。任何 channel 事件、provider 元数据或运行时环境状态都不会作为兜底被查阅。一个 scope 带着一个 `owner_uid`、一组 `readable_store_keys`、一个 `writable_store_key`，以及 `current_channel`。跨主体共享的知识有一个专门的所有者 `brain-shared`。

这种路由选择是刻意的。它把权限边界放在会话声明上——运维者看得见、改得了的地方——而不是让记忆 drifting 到最近一次说话的人那边。

## 持久事实与投影

整套模型建立在一道清晰的划分上：

- **结构化知识**——条目、块、关系、引用——是持久事实，通过带追加式审计的事务性操作写入。一个批次要么把它的变更和审计一起提交，要么不留任何局部状态。
- **Markdown 投影、搜索结果、注入的上下文**是从事实重建出来的更廉价的视图。丢一个投影只是不便；丢一行知识，意味着 agent 相信的东西变了。

所有读操作都在 SQL 里应用 owner 和可读 store 的判定，所以 scope 在数据库边缘就被强制，而不是在调用方能绕开的应用代码里。

## 召回：三个通道，一个结果

agent 回合需要记忆时，召回并行跑向两个证据来源，再合并结果：

- **聊天召回**读取 SignalsGateway 镜像下来的不可变条目，范围限定在该会话能看见的 channel。它把召回的消息当作不可信的历史数据，绝不当作指令——每一份结果集都带着这样一条提示。
- **知识召回**读取策展过的 Brain 条目和块，既用 BM25 关键词候选，也用其 embedding 上的向量候选，再在一个结果 token 预算内合并并重排。
- **search** 是合并后的入口：它并行跑两个通道，应用时间衰减以偏向较新的证据，返回一份带来源标注的排序结果集。

剧集是聊天与知识之间的桥。一个剧集是覆盖在不可变聊天事实之上的、可按时间寻址的摘要索引——主题、摘要、它所覆盖的源条目 id、一段时间范围，以及一个 embedding。它明确是一个导航索引；伴随它的提示会告诉模型，原始消息才是权威。

## dreaming：把历史转成已索引的记忆

dreaming 是离线过程，把原始聊天历史转成剧集和待定知识，而在模型这一步里没有人在场。它分两个阶段运行，频率不同，任务也不同。

**阶段 A** 是 channel 级的摘要器。它扫描含有未处理条目的 channel，并排队剧集摘要任务，每个任务请一个轻量 model profile 把一窗聊天摘要成一个剧集。当没有任何能看见该 channel 的 agent 上有可解析的轻量 profile 时，这个剧集被报告为不可用，而不是被悄悄跳过；配置禁用了 dreaming 时，这个阶段会干净地停下。

**阶段 B** 是频率更低、主体级的知识策展。它在事务之外跑模型推理，然后把经验证的小操作、skill-overlay 更新和两个实质性高水位标记一起提交——所以一次只跑了一部分的运行会被重试，而不是被悄悄跳过。产出是带着证据的待定知识，而不是对知识库的一次悄悄改动。

之所以分两阶段，是因为这两类任务的成本和风险不同。阶段 A 廉价、频繁，产出的是导航辅助；阶段 B 昂贵、不频繁，产出的是待定事实。把它们分开，昂贵的那一类才不会卡住廉价的那一类。

## 写入权限：谁能写什么

一次知识写入带着一份显式的 `WriteAuthority`，取五种模式之一：`:human`、`:agent`、`:dreaming`、`:source_learning` 或 `:mechanical`。模式决定这次写入可以引用什么、可以触碰哪些 document id。带署名的写入从受信的 scope 和 actor 推导出 owner、store 和 author；操作载荷无法覆盖它们。两种无主体的机械操作——`create_entry` 和 `delete_block`——不能署名撰写内容，并且要求一个显式的因果来源。

Brain 就是这么阻止 dreaming 与 source-learning 的产出冒充人类决定的。一份 dreaming 提案就是一次 dreaming 写入，如此标注，并附上它的证据——绝不是一次悄悄地把自己升格为权威知识。

## 人工监督

模型从不无人监督地编辑知识，也从不把自己的产出当作事实呈现。监督界面在 console 范围的路由背后：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/brain/entries` | 列出策展知识条目 |
| `GET` | `/brain/entries/:id` | 读取一个条目 |
| `POST` | `/brain/entry-operations` | 应用一批知识操作 |
| `GET` | `/brain/sources` | 列出留存的 source |
| `POST` | `/brain/sources` | 新增一个 source |
| `POST` | `/brain/sources/:document_id/learning-runs` | 运行 source 学习 |
| `GET` | `/brain/audit-log` | 读取追加式审计轨迹 |
| `POST` | `/brain/audit-log/:audit_id/restorations` | 还原一次被审计的变更 |
| `POST` | `/brain/dreaming-runs` | 触发一次 dreaming |
| `GET` | `/brain/dreaming-fitness` | 查看 dreaming 是否具备运行条件 |
| `GET` | `/brain/status` | Brain 的健康与配置状态 |

审计日志是追加式的，而每一次还原本身也被审计，所以 agent 相信过什么、谁改过它——这段历史是可以重建的。撤回一个 source 会干净地移除它；不会留下 agent 引用着它再也读不到的字节这种事。

## Brain 不是什么

它不是一个挂着聊天日志的向量库。行才是事实，向量和 Markdown 只是架在行上面的便利。它不是模型想写什么就写什么的地方——写入带着权限、证据和审计。它也不是聊天证据的所有者；那归 SignalsGateway。Brain 的边界是持久的、经过复核的、按 owner 限定范围的记忆，再加上那套提议往里写什么的离线机器。

## 下一步

- Brain 从中召回的聊天证据，读 [SignalsGateway](../signals-gateway/)。
- 给 Brain 划定 scope 的会话声明，读 [AIGateway API](../ai-gateway/)。
- 召回出的记忆如何到达一个正在跑的回合，读 [Actor Runtime](../actor-runtime/)。
