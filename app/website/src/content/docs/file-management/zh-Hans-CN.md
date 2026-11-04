---
title: 文件管理
description: 在 Console 中管理统一云盘根目录，使用 Worker 的 /drive FUSE 挂载，并了解会话附件冻结与回收站保留策略。
section: User guide
order: 31
---

**日常协作中，直接在聊天中发送附件或在 Pod 页面内协作即可，Agent 也会直接读写 `/drive` 挂载目录。仅当你需要在 Worker 未运行时查看租户各空间文件、批量上传参考数据集、取回已归档产物或跨目录整理文件时，才需要使用 Console 中的云盘浏览器。**

Ankole 通过**统一云盘（Unified Drive）**统一承载协作页面与运行时文件：`Ankole.Pod` 负责管理 `pages` 目录树、权限控制与回收站生命周期，`Ankole.Files` 负责在租户隔离的 `file_objects` 表与对象存储中保存不可变字节对象（文档内嵌资源、Base 单元格附件与 Applet 构建产物则存入独立的 `pod_files`，不会混入云盘目录列表）。会话与后台任务的工作目录（`/workspace`）位于持久 Agent Home 中而非云盘内；底层存储后端配置见 [控制面云盘存储配置](../drive-storage/)，1.x 目录导入方式见 [从 1.0 升级到 2.0](../upgrade-to-2/)。

## Worker `/drive` 挂载与命令行回退

在支持 FUSE 的 Worker 上，根监管进程会在每个命令或 Codex 子进程的私有挂载命名空间内完成 `/drive` 挂载，随后降权至无特权的 `uid 1000` 运行，并按当前执行的权限图暴露对应根目录：

| 路径 | 读写模式 | 内容说明 |
|---|---|---|
| `/drive/Public` | 读写 | 共享的 Pod 公共空间页面、文件夹与文件（对应呈现普通目录及 `._adoc.md`、`._abase`、`._aapp` 投影） |
| `/drive/MyDrive` | 读写 | 当 Agent 作为某位成员的个人助理（Personal Assistant）运行时，该人类所有者的私人空间 |
| `/drive/AgentDrive` | 读写 | Agent 自身的私有运行时根目录，存放归档输出及无会话上下文时生成的图片 |
| `/drive/ChatDrive` | 读写 | 当前对话隔离的专属根目录，存放收到的聊天附件、当前对话生成的图片与共享交付物 |
| `/drive/Brain` | 只读 | 按当前房间与请求者披露范围过滤后的 Brain 知识页面树（`._awiki.md`） |
| `/drive/Skills` | 只读 | 在 **Meta Ankole → Skills** 中管理的已启用技能包（见 [Skills](../skills/)） |
| `/drive/AGENTS.md`、`/drive/DESIGN.md` | 只读 | 在 **Meta Ankole → Agents** 中管理的最终生效行为与设计契约（见 [Agent](../agents/)） |
| `/drive-recovery` | 读写（本地） | 作用域隔离的本地恢复目录；当后台 VFS 回写遇到 `412` 或 `422` 冲突拒绝时，Worker 会在此保留草稿字节与诊断信息 |

若 Worker 启动探测发现当前运行环境无法挂载 FUSE，Ankole 会自动切换为在运行时提示中提供基于签名中继的 `ankole-files` CLI（支持 `list`、`get --node-id`、`put`、`mv`、`rm`）。Agent 向对话发送附件时，`reply_attachment` 同时支持传入云盘 `node_id` 或 `/drive/...` 路径，并在锁定已完成对象前自动刷盘待提交的 FUSE 写入。

## 在 Console 中浏览与上传文件

1. 在 Console 中切换到目标租户，打开 **Drive（云盘）**。
2. 无需启动 Worker，即可直接浏览 **Pod Space**、**Brain**、成员与 Agent 的**私人根目录**以及各**会话根目录**。
3. 进入目标文件夹后点击**上传**，即可上传单个文件或整棵目录树；向同名文件上传会更新该节点指向的 `object_id`。

建议将参考资料整理在语义清晰的固定路径下（例如 `customer-research/2026-q3-interviews.pdf`）。上传操作仅将文件写入云盘，不会主动唤醒 Agent：需要处理文件时请在对话中告知路径或关联页面；若希望将资料提炼为长期知识，请通过**学习来源**提交给 Brain。

## 会话附件、回收站与保留期

点击任意非根节点右侧的操作菜单即可移动、重命名或删除（各空间根目录本身不可移动、重命名或移入回收站）。

- **统一云盘回收站：** 删除文件或文件夹会立即将其子树移入回收站，并从云盘及 Pod 列表中隐藏。在 `drive.trash_retention_days` 到期自动清理前（默认保留 `30` 天；设为 `0` 则无限期保留，直至修改该配置），具备 `manage` 权限的管理员或所有者可随时恢复子树。永久清理前请确认重要资料已纳入常规 [备份](../backup-and-restore/)。
- **冻结的会话附件：** 消息发出时，Ankole 会在 `message_attachments` 中冻结当时的不可变 `object_id` 引用（运行时也可通过 `ankole-pod chat attachment get` 按消息位置读取该对象）。此后即使原云盘文件被覆盖、重命名、移动或移入回收站，历史消息中的附件依然完好可下载。

## Worker 重启后保留什么

统一云盘的元数据与文件对象保存在 PostgreSQL 与对象存储中，而 `/workspace` 下的代码仓库与临时产物保存在持久 Agent Home 中；两者都能跨越 Worker 重启与镜像升级持久保留。仅写入 `/workspace` 的文件仍停留在 Agent Home 内，需由 Agent 复制到 `/drive`（或通过 `ankole-files put` 上传）后才能在云盘与 Pod 中查看。各基础设施平台的存储特性详见 [工作节点](../worker-management/)。

## 常见问题

- **Agent 找不到刚上传的文件：** 在聊天消息中提供准确的 `/drive/...` 路径（或页面链接），并确认该 Agent 对所在目录具备 `view` 查看权限；在未启用 FUSE 的 Worker 上，Agent 可通过 `ankole-files list` 与 `ankole-files get --node-id` 获取节点内容。
- **云盘里看不到刚生成的产物：** 确认后台 Agent 任务是否仍在运行，或让 Agent 将 `/workspace` 内的结果复制到 `/drive/ChatDrive`、`/drive/AgentDrive` 或 `/drive/Public`。
- **FUSE 回写时发生并发修改冲突：** 若其他写入方在 Worker 缓存回写提交前修改或移动了目标节点（返回 `412` 或 `422`），可在当前执行作用域的 `/drive-recovery` 目录中找回完整草稿。
- **上传因大小超限被拒绝：** 流式对象存储后端（`fs`、`s3`、`gcs`、`azblob`、`oss`、`cos`、`tos`、`sftp`）遵循后端自身上限并受站点配置 `drive.vfs_max_upload_bytes`（非 `0` 时）约束；`postgresql` 与 `webdav` 整对象缓冲上限为 100 MiB，`d1` 单对象上限为 2,000,000 字节，结构化 Markdown 页面投影上限为 100 MiB。
