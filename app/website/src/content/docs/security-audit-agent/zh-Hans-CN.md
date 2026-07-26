---
title: 安全审计 agent
description: 如何设置一个扫描代码库安全问题的 agent——依赖漏洞、注入风险、硬编码 secret——带严重度和修复建议报告。
section: Guides
order: 349
---

一个安全审计 agent 读代码库、扫描常见安全问题——已知漏洞依赖、注入风险、硬编码 secret、错误配置的 auth——每项发现带严重度和修复建议报告。本指南是那个 agent 的实际形态。

先把决定性的性质说清楚：agent **审计，不打补丁**。它识别问题并报告。人决定修、推迟、还是接受风险。agent 的价值是覆盖和一致性，不是改安全关键代码的权威。

## 需要什么

- **WorkerEnv 里的 git 凭证**（`GIT_TOKEN`）。见 [Git 集成](../git-integration/)。
- **绑定 `primary` 和 `coding` profile**——安全分析需要代码理解能力。
- **一个 signal binding** 到审计报告发帖的频道。
- **repo 从 worker 可达。**

## 工作流

1. **审计任务到达**——定时扫描、发布前检查、或人请求。
2. **agent 克隆并扫描**——跑依赖检查（`npm audit`、`bun audit`、`pip-audit` 等）、读代码找注入模式、检查硬编码 secret、检查 auth 配置。
3. **agent 分类**——严重度（critical/high/medium/low）、类别（依赖、注入、secret、配置）、可利用性。
4. **agent 建议修复**——每项发现：做什么（升级、打补丁、移除、配置），带具体版本或配置变更。
5. **agent 报告**——结构化报告：按严重度排列的发现，附文件、问题、证据、和修复建议。

## 人设控制什么

- **范围**——"扫描依赖、源代码和配置文件。不扫描测试夹具或生成代码。"
- **严重度阈值**——"critical 和 high 立即报告；medium 和 low 批进每周摘要。"
- **修复深度**——"建议升级到的具体版本，附 CVE 链接。代码问题建议修复模式但不写补丁。"
- **Secret 检测**——"用模式匹配检查硬编码 API key、密码和 token。标记任何看起来像凭证的东西。"

## 已知漏洞检查

最有价值的自动化检查是依赖扫描。agent 跑语言生态系统的审计工具：

```bash
bun audit    # Bun/Node
pip-audit    # Python
cargo audit  # Rust
mix deps.audit # Elixir（若工具可用）
```

每个发现的漏洞，agent 报告：包、CVE、严重度、和修复版本。

## 一个完整示例

为 Bun + TypeScript repo 设置每周安全审计 agent：

1. 在 WorkerEnv 存 `GIT_TOKEN`。
2. 创建 agent，绑 `primary`/`coding`。
3. 撰写 `MISSION.md`："每周一，克隆 repo。跑 `bun audit` 查依赖漏洞。扫描源文件找硬编码 secret 和注入模式（eval、exec、SQL 字符串拼接）。按严重度报告：critical/high 立即发 #security，medium/low 进每周摘要。建议修复（升级版本、修复模式）。不打补丁。"
4. 加一条每周调度：`cron: "0 8 * * 1"`。
5. agent 克隆、审计、扫描、分类、发报告。

## 本指南不是什么

它不是渗透测试器——agent 扫描源代码和依赖，不是运行中的系统。它不是 SAST 替代——agent 用模式匹配和工具输出，不是正式数据流分析。它也不是修复——它报告；团队修。安全关键变更始终需要人工复核。

## 下一步

- git 设置，读 [Git 集成](../git-integration/)。
- shell 工具（跑审计命令），读[代码执行](../code-execution/)。
- Ankole 部署自身的安全加固，读[安全加固](../security-hardening/)。
- 调度，读 [Cron 调度](../cron-schedules-ops/)。
