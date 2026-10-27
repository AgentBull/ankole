---
title: Jupyter 数据分析
description: 配置 Agent 通过常驻 Jupyter Kernel 执行交互式 Python 数据分析——涵盖 jupyter-live-kernel Skill、DataFrame 探查与完整示例。
section: Guides
order: 304
---

数据分析天然是一个反复迭代的过程：查看 DataFrame、调整查询逻辑、绘制图表，如此循环往复。单次运行的 Python 进程无法在多次调用之间保留内存状态，而 `jupyter-live-kernel` Skill 则在后台维护一个常驻的 Jupyter Kernel，供 Agent 跨多个单元格（Cell）连续驱动，完整保留上下文状态。本文将介绍这类数据分析 Agent 的实际配置与工作方式。

核心机制在于：Jupyter Kernel **跨单元格保持状态**。无论是普通变量、DataFrame、已导入的库还是绘图上下文，都会在 Agent 的多次调用之间持续有效，因此无需每一步都重新加载数据或重复导入依赖库。

## 需要什么

- **启用 `jupyter-live-kernel` Skill。** 该 Skill 默认开启（`default_enabled: true`），详见 [Skills](../skills/)。
- **准备 Worker 镜像。** Agent Computer Worker 镜像已内置 Python、Jupyter 及 `hamelnb` Kernel，开箱即用。
- **绑定 `primary` 模型档案。** 由 Agent 编写 Python 代码，交由 Kernel 执行。

## 何时用 kernel vs 一次性脚本

以下场景适合使用 Jupyter Kernel：

- **交互式迭代分析**：需要反复查看中间结果、调整逻辑并再次验证；
- **需要跨步保留内存状态**：例如复用已加载的 DataFrame、已拟合的模型或已导入的第三方库；
- **数据探查阶段**：在编写最终查询逻辑前，需要先摸清数据结构与分布形态。

以下场景更适合通过 `command` 工具运行一次性 Python 进程：

- **无状态脚本**：只需运行一次、输出结果即可结束；
- **批量文件转换**：直接转换文件格式，中途无需检查中间状态。

正如该 Skill 的 `SKILL.md` 所述：“无状态脚本优先用一次性 Python 进程。”

## kernel 如何工作

`jupyter-live-kernel` Skill 以常驻后台任务的形式运行（`ankole-runtime: background_job`）。任务启动后会在 Worker 内拉起一个 Jupyter Kernel，Agent 随后通过该 Skill 提供的工具依次发送代码单元格。每个单元格都在同一份内存状态中执行——例如在第 1 个单元格中定义的变量，到了第 5 个单元格依然可以直接引用。

在后台任务运行期间，Kernel 会一直保持存活；一旦任务结束，Kernel 随之停止，内存中的临时执行状态也会一并释放，不会持久化保存。

## 一个完整示例

下面配置一个专门分析团队在频道中所发 CSV 文件的 Agent：

1. 确认 `jupyter-live-kernel` Skill 已启用（默认开启）。
2. 创建 Agent 并编写 `MISSION.md`：“当频道中出现 CSV 文件时，将其加载进 DataFrame，检查字段结构与汇总统计量，识别异常值，并配图汇报分析结论。”
3. 在频道中直接上传 CSV 附件，或在 Console 中将其上传至 Agent 云盘并在对话中给出路径。
4. 收到请求后，Agent 会将工作委派给后台任务，启动 Kernel 加载 CSV，经过多轮交互检查与图表生成后，将分析结果发回频道。

## 本指南不是什么

- **不是 Python 或 pandas 教程**：分析代码由 Agent 自行编写，Skill 仅负责提供执行环境。
- **不是 Notebook 创作指南**：Kernel 主要供 Agent 在推理过程中交互调用，而非专门产出持久保存的 `.ipynb` 文件（当然，若任务明确要求，Agent 也可以保存一份 Notebook）。
- **不替代阅读 `SKILL.md`**：关于该 Skill 的权威调用规范，仍以其自带的 `SKILL.md` 为准。

## 下一步

- 深入了解 Skill 机制，请参阅 [Skills](../skills/) 与 [编写 skill](../writing-a-skill/)。
- 了解 Shell 工具用法，请参阅 [代码执行](../code-execution/)。
- 了解后台执行机制，请参阅 [后台 Agent 任务](../background-jobs/)。
- 了解如何向 Agent 上传文件，请参阅 [文件管理](../file-management/)。
