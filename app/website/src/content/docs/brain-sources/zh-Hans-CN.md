---
title: Brain source
description: 如何管理 Brain 可从中学习的留存 source 文档——添加、列出、读取、触发学习运行、撤回 source。
section: User guide
order: 55
---

Brain source 是 agent 可以从中学习的留存文档——上传的参考材料、导入的知识、策略文档。与策展知识条目（运维者直接撰写）不同，source 是 Brain 学习过程从中提取知识的原材料，产出 `source_learning` 权限的提案供人复核。本页是 source 管理面的任务导向运维视角。

先把决定性的性质说清楚：source 是**原材料，不是知识**。加一个 source 不改变 agent 知道什么；对它运行学习产出提案知识，必须经复核才成为权威。source 是输入；经复核的知识是输出。

## 列出 source

```bash
curl https://ankole.example.com/api/v1/brain/sources \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /brain/sources` 列出留存 source。每个带一个 `document_id`（形如 `brain-source:<id>`）、其 content hash 和元数据。

## 添加 source

```bash
curl -X POST https://ankole.example.com/api/v1/brain/sources \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "document_id": "brain-source:onboarding-doc", "content": "..." }'
```

`POST /brain/sources` 存储一个 source 文档。内容被留存；Brain 在你触发学习运行时可以从中学习。

## 读取 source

```bash
curl https://ankole.example.com/api/v1/brain/sources/<document_id> \
  -H "Authorization: Bearer $CONSOLE_TOKEN"

curl https://ankole.example.com/api/v1/brain/sources/<document_id>/raw \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /brain/sources/:document_id` 返回 source 的元数据；`/raw` 返回其内容。

## 触发学习运行

```bash
curl -X POST https://ankole.example.com/api/v1/brain/sources/<document_id>/learning-runs \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`POST /brain/sources/:document_id/learning-runs` 对一个 source 触发学习运行。Brain 读取 source、提取知识、产出带 `source_learning` 权限的提案。这些提案出现在 Brain 审计日志中供复核——它们不经人批准就不成为权威，通过 [Brain 复核](../brain-review-ops/)界面操作。

## 撤回 source

撤回一个 source 从 Brain 的留存集中移除它。source 撤回是干净的——它不删除已从该 source 提取并经复核的知识；它停止将来的学习运行读取它。source 过时或误加时用撤回。

## source 与知识条目的关系

| | Source | 知识条目 |
|---|---|---|
| 是什么 | 原始文档（参考材料、策略） | 策展事实（持久真相） |
| 谁创建 | 运维者上传 | 运维者撰写，或 dreaming/source-learning 提案+人复核 |
| 权限 | 无（它是输入） | `human`、`agent`、`dreaming`、`source_learning`、`mechanical` |
| 学习 | Brain 通过学习运行从中学习 | 它是 Brain 学到的——已复核 |
| 出现在审计日志 | 否（它不是知识写入） | 是（每次写入被审计） |

source 喂养知识库；它不是知识库的一部分。加好 source 并运行学习产出知识；移除 source 不遗忘已批准的东西。

## 一个完整示例

1. `POST /brain/sources`——把公司 onboarding 手册作为 source 上传。
2. `POST /brain/sources/<id>/learning-runs`——让 Brain 从中提取知识。
3. `GET /brain/audit-log`——复核 `source_learning` 提案。
4. `POST /brain/entry-operations`——批准对的、还原错的。
5. 被批准的提案现在是 `source_learning` 权限的知识条目，agent 可召回。

## 本指南不是什么

它不是 Brain 概念页——记忆模型、召回、dreaming 见 [Brain](../brain/)。它不是知识复核指南——复核提案见 [Brain 复核](../brain-review-ops/)。它不是 memory 工具指南——agent 的 `memory_search`/`memory_open` 工具见 [Memory](../memory/)。

## 下一步

- Brain 概念页，读 [Brain](../brain/)。
- 复核学习提案，读 [Brain 复核](../brain-review-ops/)。
- agent 的 memory 工具，读 [Memory](../memory/)。
- Console 路由，读 [Console API 参考](../console-api/)。
