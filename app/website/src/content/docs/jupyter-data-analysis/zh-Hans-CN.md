---
title: Jupyter 数据分析
description: 如何设置一个通过 live Jupyter kernel 运行迭代 Python 数据分析的 agent——jupyter-live-kernel skill、DataFrame 检查、完整示例。
section: Guides
order: 328
---

数据分析是迭代的——检查 DataFrame、调整查询、画结果、重复。一次性 Python 进程无法在调用间保持状态。`jupyter-live-kernel` skill 通过运行一个 agent 跨多个 cell 驱动的 live Jupyter kernel 解决它，保持状态。本指南是一个数据分析 agent 的实际形态。

先把决定性的性质说清楚：Jupyter kernel **跨 cell 有状态**。变量、DataFrame、import 和绘图状态在 agent 的调用间持久。这让迭代分析成为可能——agent 不必每步重载数据或重新 import 库。

## 需要什么

- **`jupyter-live-kernel` skill 已启用。** 它是 `default_enabled: true`。见 [Skills](../skills/)。
- **worker 镜像。** Agent Computer 镜像安装了 Python、Jupyter 和 `hamelnb` kernel。这些是镜像的一部分。
- **绑定 `primary` model profile。** agent 写 Python 代码；kernel 执行它。

## 何时用 kernel vs 一次性脚本

用 Jupyter kernel 当：

- 工作是**迭代的**——检查、调整、再检查
- **状态必须持久**——加载的 DataFrame、拟合的模型、import 的库
- agent 需要在写最终查询前**探索**数据形态

用一次性 Python 进程（通过 `command`）当：

- 脚本**无状态**——跑一次、产出、完成
- 工作是**批量转换**——转换文件、无需检查

skill 的 `SKILL.md` 说："无状态脚本优先用一次性 Python 进程。"

## kernel 如何工作

`jupyter-live-kernel` skill 作为后台任务运行（`ankole-runtime: background_job`）。它在 worker 中启动一个 Jupyter kernel，agent 通过 skill 的工具向它发 cell。每个 cell 在 kernel 的持久状态中执行——cell 1 定义的变量在 cell 5 可用。

kernel 在后台任务期间保持存活。任务结束时 kernel 停止、其状态消失——它是临时执行状态，不持久。

## 一个完整示例

设置一个分析团队丢进频道的 CSV 的 agent：

1. 确认 `jupyter-live-kernel` skill 已启用（默认是）。
2. 创建 agent，撰写 `MISSION.md`："当频道里出现 CSV，把它加载进 DataFrame，检查 schema 和汇总统计，识别异常，用图表报告发现。"
3. 在频道里上传一个 CSV（通过 worker-file 路由或提供 URL）。
4. agent 委派给后台任务，启动 kernel，加载 CSV，迭代检查，生成图表，回报。

## 本指南不是什么

它不是 Python 或 pandas 教程——agent 写代码；skill 提供执行环境。它不是 notebook 创作指南——kernel 供 agent 使用，不是产出保存的 notebook（尽管任务要求时 agent 可以保存一个）。它也不是读 skill 的 `SKILL.md` 的替代——那个文件是权威参考。

## 下一步

- skill 系统，读 [Skills](../skills/)和[编写 skill](../writing-a-skill/)。
- shell 工具，读[代码执行](../code-execution/)。
- 后台任务，读[后台任务（运维视角）](../background-jobs-ops/)。
- 上传文件到 worker，读 [Worker 文件](../worker-files/)。
