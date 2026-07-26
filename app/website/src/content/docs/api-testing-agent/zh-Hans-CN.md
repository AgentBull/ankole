---
title: API 测试 agent
description: 如何设置一个测试 API 端点的 agent——发请求、检查响应、带证据报告失败、覆盖静态测试套件遗漏的边界情况。
section: Guides
order: 347
---

一个 API 测试 agent 向 API 发请求、按预期检查响应、带足够证据报告失败。它通过适应——试边界情况、变参数、探索 API 行为边界——超越静态测试套件。本指南是那个 agent 的实际形态。

先把决定性的性质说清楚：agent **测试，不修**。它发请求、验证响应、报告。人决定失败是 bug、文档缺口、还是预期行为。agent 的价值是覆盖和适应性，不是诊断权威。

## 需要什么

- **绑定 `primary` 和 `coding` profile**——写和调整测试请求需要推理 API 契约。
- **一个 signal binding** 到测试报告发帖的频道。
- **API 从 worker 可达**——agent 启动的本地 dev 服务器、staging URL、或内部端点。
- **API 凭证（若需要）**——存为 WorkerEnv secret。

## 工作流

1. **测试任务到达**——"测试 `/payments` 端点"、"验证重构后的 auth 流程"、或一条定时冒烟测试。
2. **agent 读 API 契约**——从 OpenAPI spec、已有测试、或代码库的路由定义。
3. **agent 发请求**——通过 `command` 用 `curl`、或通过 agent 写的脚本。覆盖正常路径、错误情况、边界情况（空输入、非法类型、边界值）。
4. **agent 验证响应**——状态码、响应形态、字段类型、业务逻辑正确性。
5. **agent 报告**——结构化报告：通过、失败（附请求+响应+预期）、和模糊的。

## 什么是让它成为 agent 而非测试运行器

测试运行器执行固定的断言集。agent 适应：

- **边界情况探索**——正常路径通过后，agent 试测试套件未覆盖的变化："金额为负怎么办？货币小写怎么办？auth token 过期怎么办？"
- **契约验证**——agent 读 API spec 并检查实际响应是否匹配文档化的契约，不只看状态码是否 200。
- **失败调查**——测试失败时，agent 读错误响应、识别可能原因、包含在报告里。

## 一个完整示例

设置一个每晚冒烟测试 REST API 的 agent：

1. 绑 `primary`/`coding` + 把 staging API key 存 WorkerEnv（`STAGING_API_KEY`）。
2. 撰写 `MISSION.md`："每晚冒烟测试 staging API。读 OpenAPI spec。测每个端点的正常路径。按 spec 检查状态码和响应形态。每个端点试 2-3 个边界情况。报告：通过、失败（附请求+响应+预期）、模糊。不修。"
3. 加一条每晚调度：`cron: "0 3 * * *"`。
4. agent 读 spec、通过 `command` 发 `curl` 请求、验证响应、试边界情况、发报告。

## 委派大型测试套件

端点多的 API，把测试运行委派给后台任务（见[委派模式](../delegate-patterns/)）。任务跑全套；任务完成时 agent 综合报告。

## 本指南不是什么

它不是负载测试工具——agent 发顺序请求，非并发负载。负载测试用专用工具（k6、Locust、wrk）。它不是安全扫描器——agent 测功能正确性，不测漏洞。它也不是 CI 门控——agent 报告；团队决定挡什么。

## 下一步

- shell 工具（通过 `command` 的 `curl`），读[代码执行](../code-execution/)。
- coding profile，读 [Provider 与模型](../providers-and-models/)。
- 调度，读 [Cron 调度](../cron-schedules-ops/)。
- 委派，读[委派模式](../delegate-patterns/)。
