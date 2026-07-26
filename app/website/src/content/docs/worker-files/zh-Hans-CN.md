---
title: Worker 文件
description: 如何在 worker 的 Agent Home 文件系统上上传、下载、移动和删除文件——Console 路由及各自做什么。
section: User guide
order: 47
---

worker 的 Agent Home 文件系统是 agent 在回合中读写文件的地方。有时运维者需要直接管理这些文件——上传参考文档、下载生成的产物、移动放错的文件、清理旧工作。本页是通过 Console worker-file 路由做这些操作的运维界面。

先把决定性的性质说清楚：这些路由操作**特定 worker 的文件系统**，不是逻辑 agent。路由按 `worker_id` 范围限定，移动该 worker Agent Home 卷上的真实文件。文件系统之上没有"agent 文件存储"抽象——文件系统就是存储。

## 路由

五条 Console 路由覆盖运维者的文件操作：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/agent-computer-workers/:worker_id/files` | 列出 worker 文件系统根的文件 |
| `GET` | `/agent-computer-workers/:worker_id/files/content` | 下载一个文件 |
| `POST` | `/agent-computer-workers/:worker_id/files` | 上传一个文件 |
| `POST` | `/agent-computer-workers/:worker_id/file-moves` | 重命名或移动路径 |
| `DELETE` | `/agent-computer-workers/:worker_id/files` | 删除一个文件或目录 |

每条路由按 `worker_id` 定位 worker——与 `GET /agent-computer-workers` 里可见的同一 id。文件路径相对于 worker 的 Agent Home 根（`/agents`）。

## 上传文件

上传 agent 需要的参考文档或模板：

```bash
curl -X POST https://ankole.example.com/api/v1/agent-computer-workers/<worker_id>/files \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -F "path=user-files/reference.md" \
  -F "file=@local-file.md"
```

上传的文件落在相对于 Agent Home 的指定路径。用 `user-files/` 目录放运维者提供的文件——这是 agent 应当看到但不是它自己创建的文件的常规位置。

## 下载文件

取回生成的产物——agent 写的报告、产出的图表、保存的日志：

```bash
curl -o output.pdf https://ankole.example.com/api/v1/agent-computer-workers/<worker_id>/files/content \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -G -d "path=jobs/42/output.pdf"
```

路径相对于 Agent Home。响应是文件的原始字节。

## 移动或重命名文件

```bash
curl -X POST https://ankole.example.com/api/v1/agent-computer-workers/<worker_id>/file-moves \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "from": "temp/draft.md", "to": "user-files/final.md" }'
```

移动在文件系统上是原子的——文件出现在目标处、从源消失。用它重定位 agent 放错的文件，或把草稿提升到永久位置。

## 删除文件

```bash
curl -X DELETE https://ankole.example.com/api/v1/agent-computer-workers/<worker_id>/files \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -G -d "path=temp/old-output.txt"
```

删除是永久的——文件从文件系统移除，不进回收站。用它清理；不要用它删可能想要回的东西（改为从备份还原——见[备份与还原](../backup-and-restore/)）。

## 本指南不是什么

它不是文件传输协议参考——文件传输 lane（RuntimeFabric）是 [Kernel](../kernel/) 页的范围。它不是权限指南——worker 在 bubblewrap 下运行，上述路径是 agent 在该 sandbox 内看到的。它也不是[文件管理](../file-management/)页的替代——那页覆盖布局和持久模型；本页覆盖运维者的文件操作。

## 下一步

- Agent Home 布局与持久性，读[文件管理](../file-management/)。
- Console 路由，读 [Console API 参考](../console-api/)。
- 备份，读[备份与还原](../backup-and-restore/)。
