---
title: 性能分析 agent
description: 如何设置一个分析代码性能的 agent——识别慢函数、测量瓶颈、带证据报告。
section: Guides
order: 351
---

一个性能分析 agent 对代码库跑 profiler、识别最慢的函数和最大的瓶颈、带计时数据和优化方向建议报告它们。本指南是那个 agent 的实际形态。

先把决定性的性质说清楚：agent **分析和报告，不优化**。它测量时间花在哪、识别热路径、建议看什么。人写优化；agent 提供证据。价值在于快速找到瓶颈，不在于修复它。

## 需要什么

- **WorkerEnv 里的 git 凭证**（`GIT_TOKEN`）。见 [Git 集成](../git-integration/)。
- **绑定 `primary` 和 `coding` profile**——读 profiler 输出和识别热路径需要代码理解能力。
- **一个 signal binding** 到分析报告发帖的频道。
- **repo 从 worker 可达**，能在 profiler 下运行代码。

## 工作流

1. **分析任务到达**——"分析 `/payments` 的 API 响应时间"、或一条定时检查。
2. **agent 跑 profiler**——语言的 profiling 工具：`bun --prof`、`node --prof`、`py-spy`、`perf`、或基准脚本。
3. **agent 读输出**——识别按时间排名的前 N 个函数、调用频率、和分配热点。
4. **agent 映射到源码**——把每个热函数连到其文件和行、读代码、识别可能原因（嵌套循环、N+1 查询、不必要的分配）。
5. **agent 报告**——结构化报告：带计时的前几个瓶颈、源码位置、可能原因、和建议方向（不是补丁）。

## 人设控制什么

- **分析目标**——"分析测试套件最慢的 5 个测试"vs"分析特定 API 端点在负载下"。
- **工具选择**——"Bun 代码用 `bun --prof`，Python 用 `py-spy`。"
- **报告深度**——"按 self-time 排前 10 个函数，附源码位置和一句话诊断。"
- **不做什么**——"不写优化。报告瓶颈和建议方向。不改代码。"

## 一个完整示例

为 Bun API 设置性能分析 agent：

1. 在 WorkerEnv 存 `GIT_TOKEN`。
2. 创建 agent，绑 `primary`/`coding`。
3. 撰写 `MISSION.md`："通过对测试套件跑 `bun --prof` 分析 API。识别按 self-time 排前 10 的函数。每个报告：函数名、file:line、self-time、调用次数、可能原因（循环、分配、I/O）、建议方向。不优化。把报告发到频道。"
4. 在频道里："分析 payments 端点——上次部署后一直慢。"
5. agent 克隆、分析、读输出、映射到源码、发报告。

## 本指南不是什么

它不是 APM 工具——agent 按需分析，非生产持续。它不是自动优化器——它找瓶颈；人修。它也不是负载测试器——它分析正确性路径性能，非并发负载下行为（那个见 [API 测试 agent](../api-testing-agent/)）。

## 下一步

- git 设置，读 [Git 集成](../git-integration/)。
- shell 工具（跑 profiler），读[代码执行](../code-execution/)。
- coding profile，读 [Provider 与模型](../providers-and-models/)。
- 相关的 API 测试模式，读 [API 测试 agent](../api-testing-agent/)。
