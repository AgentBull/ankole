---
title: 文件管理
description: 在 Console 中上传参考资料、下载 Agent 产物，并管理 Agent 的云盘。
section: User guide
order: 31
---

**多数情况下，你不需要使用本页介绍的文件浏览器。在对话中直接向 Agent 发送文件，即可创建、读取、修改、整理或传输文件。仅当需要找回未送达的产物、检查已保存的输出或手动整理文件夹时，才使用 Console 文件浏览器。**

每个 Agent 的控制面云盘保存附件、图片、发布的文件、已安装 Skill 和 Automation 脚本。没有 Worker 运行时，Console 也能上传、下载、移动和删除它们。Session 与 Job 工作区在持久 Home 中，不是云盘文件夹。

部署人员可按 [控制面云盘存储配置](../drive-storage/)设置本地文件夹、S3 或 R2；旧 Home 的文件导入见 [从 1.0 升级到 2.0](../upgrade-to-2/)。

## 找到 Agent 的文件

1. 在 Console 中打开 **Agent**，再打开目标 Agent。
2. 在**云盘**下选择**浏览文件**。

| 文件夹 | 内容 |
|---|---|
| `inbox/` | 别人发给 Agent 的附件 |
| `generated/` | Agent 生成的图片 |
| `sent/` | Agent 随回复发出的文件 |
| `skills/` | Agent 已安装的 Skill，每个 Skill 一个文件夹 |
| `automation/` | Automation Job 脚本 |
| 其他文件夹 | Agent 或用户保存的文件 |

## 上传参考资料

1. 打开目标文件夹，或在上传时填写文件夹。
2. 选择**上传**并添加文件。同一路径上已有的文件会被替换。
3. 在对话中告诉 Agent 云盘路径和任务。

上传时会自动创建路径中的文件夹。使用稳定的名称，例如 `customer-research/2026-q3-interviews.pdf`。不要把所有文件都放在根目录，也不要使用 `final-v2-new.pdf` 这类无法说明内容的名称。

上传只让 Agent 能取到文件，不会开始工作。请在对话中告诉 Agent 使用它。若要把资料沉淀为长期知识，请通过**学习来源**提交。

## 下载 Agent 产物

云盘保存 Agent 保存的文件，以及它随回复发出的文件（在 `sent/` 下）。Agent 只写在对话工作区中的文件不在云盘里；请让 Agent 把它保存到云盘。

如果附件已经在对话中送达，直接在对话中下载即可。Console 用于找回未送达的产物、检查已保存的输出，或整理需要保留的结果。

## 移动和删除

在文件或文件夹的操作菜单中可以移动、重命名或删除。移动不会改变文件内容。

删除是永久操作，没有回收站。删除文件夹会删除其中的全部文件。清理前先确认 Agent 没有正在使用这些文件。

重要内容应先下载，或确认已经包含在 [备份](../backup-and-restore/) 中。

`skills/` 下的文件就是已安装的 Skill。修改它们会在下一个回合改变该 Skill。Skill 的启用状态通过 [Agent 能力库](../skills/) 管理。

## 重启后保留什么

云盘与持久 Home 都跨 Worker 实例保留。Agent 只写到工作区的文件留在 Home；发布到云盘后才能在 Console 下载。各类型的存储限制见 [工作节点](../worker-management/)。

Agent 的 `MISSION`、`SOUL` 和 `DESIGN` 文档由 Console 的 Agent 编辑页管理。它们会投影到 Worker，不是云盘文件。如何配置这些文档见 [Agent](../agents/)。

## 常见问题

- **Agent 找不到上传的文件：** 在消息中写明准确的云盘路径。Agent 会用 `ankole-files get` 取回它。
- **生成的产物不见了：** 让 Agent 把它保存到云盘，或确认 Job 已经完成。
- **上传因大小失败：** 单个文件最大 100 MiB。
- **附件显示为不可取用：** 它在云盘出现之前到达，或下载失败。请发送者重新发送。
