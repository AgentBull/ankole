---
title: Brain 复核
description: 如何复核和策展 agent 记住的东西——读取知识条目、检查审计轨迹、还原先前状态、按需运行 dreaming。
section: User guide
order: 51
---

Brain 持有 agent 的长期记忆——策展知识、源聊天召回、dreaming 提案。人复核这份记忆以保持其准确、移除陈旧事实、批准或拒绝 dreaming 的提案。本页是复核面的任务导向运维视角，通过 Console 的 `/brain/*` 路由。

先把决定性的性质说清楚：Brain 知识是**经人复核的持久事实**。Dreaming 提案；运维者决定。Dreaming 产出的任何东西，不经一次经复核的写入就不成为权威知识。复核面就是那种人工监督发生的地方。

## 读取知识条目

```bash
curl https://ankole.example.com/api/v1/brain/entries \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /brain/entries` 列出 agent 持有的策展知识条目。用 `GET /brain/entries/:id` 读取一个。每个条目带其类型、store key、摘要、属性，以及谁在何时改过它的审计轨迹。

## 读取审计轨迹

```bash
curl https://ankole.example.com/api/v1/brain/audit-log \
  -H "Authorization: Bearer $CONSOLE_TOKEN"

curl https://ankole.example.com/api/v1/brain/entries/<id>/audit-log \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

审计日志是追加式的——每次知识写入、删除和还原产生一行。这是"agent 为什么相信那个？"的界面。行里命名 actor（human、agent、dreaming、source_learning、mechanical）、操作、时间戳。

## 应用知识操作

```bash
curl -X POST https://ankole.example.com/api/v1/brain/entry-operations \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "operations": [ ... ] }'
```

`POST /brain/entry-operations` 应用一批知识变更——创建条目、更新块、删除块。一个批次要么把所有变更和审计一起提交，要么不留任何局部状态。运维者的权限模式是 `human`；操作把该权限带进写入。

## 还原先前状态

```bash
curl -X POST https://ankole.example.com/api/v1/brain/audit-log/restorations \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "audit_id": "<audit-id>" }'

curl -X POST https://ankole.example.com/api/v1/brain/audit-log/<audit_id>/restorations \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

还原通过应用其逆操作撤销一次特定审计过的变更。还原本身被审计——它加一行新审计行，不擦除做出原始改动的那一行。知识写入错了时用还原；不要随意用，因为每次还原是轨迹中的一条新决定。

## 管理 source

```bash
curl https://ankole.example.com/api/v1/brain/sources \
  -H "Authorization: Bearer $CONSOLE_TOKEN"

curl -X POST https://ankole.example.com/api/v1/brain/sources \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "document_id": "brain-source:...", ... }'

curl -X POST https://ankole.example.com/api/v1/brain/sources/<document_id>/learning-runs \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

source 是 Brain 可以从中学习的留存文档——上传的参考材料、导入的知识。列出它们、添加一个、触发学习运行让 Brain 从 source 提取知识。source 学习产出 `source_learning` 权限的写入，如此标注。

## 按需运行 dreaming

```bash
curl https://ankole.example.com/api/v1/brain/dreaming-fitness \
  -H "Authorization: Bearer $CONSOLE_TOKEN"

curl -X POST https://ankole.example.com/api/v1/brain/dreaming-runs \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /brain/dreaming-fitness` 告诉你 dreaming 是否具备运行条件——配置是否启用、是否有可用的轻量 profile、是否有未处理的条目。`POST /brain/dreaming-runs` 手动触发一次运行。Dreaming 的产出是带 `dreaming` 权限的提案知识——不经人复核就不成为权威。

## 检查 Brain 健康

```bash
curl https://ankole.example.com/api/v1/brain/status \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /brain/status` 显示 Brain 的配置与健康——知识是否启用、dreaming 是否启用、embedding 模型是否配置。Brain 似乎不工作时用它做第一项检查。

## 一个完整复核会话

1. `GET /brain/entries`——扫 agent 当前知道什么。
2. `GET /brain/audit-log`——检查近期变更，尤其来自 `dreaming` 或 `agent` 权限的。
3. 若 dreaming 提案错了，`POST /brain/audit-log/<id>/restorations` 撤销它。
4. 若某事实陈旧，`POST /brain/entry-operations` 带删除或更新。
5. `POST /brain/dreaming-runs` 若想让 Brain 处理近期历史——然后复核提案。

## 本指南不是什么

它不是 Brain 概念页——记忆模型、召回、dreaming 内部见 [Brain](../brain/)。它不是 memory 工具指南——agent 在回合中用的工具见 [Memory](../memory/)。它也不是审计轨迹页的替代——跨子系统审计地图见[审计轨迹](../audit-trail/)。

## 下一步

- Brain 概念页，读 [Brain](../brain/)。
- agent 的 memory 工具，读 [Memory](../memory/)。
- 审计地图，读[审计轨迹](../audit-trail/)。
- Console 路由，读 [Console API 参考](../console-api/)。
