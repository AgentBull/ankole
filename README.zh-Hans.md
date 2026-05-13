# BullX — 次世代 AgentOS

[![License](https://img.shields.io/badge/license-Apache%202.0-red.svg?logo=apache&label=License)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.19-48205D?logo=elixir)](https://elixir-lang.org)

[English](./README.md) | [简体中文](./README.zh-Hans.md) | [日本語](./README.ja.md)

> :warning: **BullX 仍处于早期开发阶段。当前分支是一次大规模减法清理后的 infra shell，具体产品细节会继续通过 design doc 演进。**

BullX 是一个 general-purpose AgentOS，基于 Elixir/OTP 和 PostgreSQL 构建，面向长期运行的数字化工作负载。它可以服务企业团队、小型运营组织，也可以服务 OPC（one-person company）。核心思路是一致的：Agent 感知 Signal，承担 Work，通过受治理的 Capability 行动，记住 Outcome，并持续改进。

BullX 不只是聊天 bot 框架，也不只是 LLM tool runner。它的长期目标是让持久 Agent 安全参与真实工作。

## 当前状态

当前分支只保留基础设施外壳：

- Elixir/OTP 应用启动与 supervision
- PostgreSQL Repo 与动态配置
- UUIDv7 与 native helper 边界
- i18n catalog 基础设施，产品文案为空
- Phoenix、Inertia、Rsbuild、UIKit 和 setup placeholder SPA
- health endpoints 与 OpenAPI description plumbing
- `packages/` 下可复用的独立包

已经删除的产品表面不应被零散恢复；新的产品行为应来自 design doc。

## 产品方向

BullX 围绕少数持久概念组织。具体表设计、进程拓扑、队列名称和 provider adapter 尚未定稿。

- **Installation** — 一套 BullX 部署及其运行域。BullX 是通用 AgentOS，但默认不把 SaaS 多租户作为产品边界。
- **Principal** — 可被授权、审计和归责的内部主体。人类、Agent、service 和 system actor 都是 Principal。
- **Agent** — 具备身份、职责、记忆、能力、权限、出站身份和 KPI 的持久工作主体。Agent 不自动等于 LLM 进程或聊天 bot。
- **Signal** — 标准化表达“发生了什么”。Signal 不是任务。
- **Admission** — 决定某个 Signal 是否进入某个 Agent 的注意力空间，并记录 owner、observer、reviewer、delegate、subscriber 或 blocked 等关系。
- **Work / Mission** — 长期责任。Mission 是持久目标，Work 是具体承诺。
- **Capability** — Agent 可使用的受治理能力，可由 reasoning、browser、code、messaging、data、memory、approval 等 provider 支撑。
- **Intent / Governance / Effect** — Agent 先提出 Intent；Governance 判断它能否成为 Effect；Effect 产生 Outcome 和 audit record。
- **Brain** — 未来的本体论与推理式记忆层，围绕 object、relationship、perspective、engram 和 consolidation，而不是原始向量日志。

## 用户故事

### 群聊旁听但不插话

客户成功 Agent 可以旁听客户群，静默处理风险 Signal，创建或更新 Work，并私下通知负责人；默认不在群里发言。

### 同一 Signal 准入多个 Agent

同一个外部事件可以以不同关系影响不同 Agent。客户预算冻结的消息可能让 CustomerSuccessAgent 成为 owner，让 FinanceAgent 成为 observer，让无关 Agent 被 blocked。

### 同时记住对话和外部事件

投研 Agent 可以把用户对话与市场、政策、运营事件放在同一套记忆系统里。未来回答问题时，应通过本体论世界模型检索上下文，而不只是搜索历史聊天文本。

### 从 Outcome 中改进

Agent 应该从重复结果中学习。如果 coding Agent 经常因为缺少 fixture 上下文而失败，后续 Work planning 应优先收集 fixture 信息再生成 patch。

### 治理高风险出站行为

Agent 不应直接产生面向客户、金融、法律或其他高风险的外部影响。它先创建 Intent，Governance 判断风险和审批要求，只有通过的 Intent 才能成为外部 Effect。

## 设计不变量

- PostgreSQL 是持久事实源。
- 进程内状态必须是临时的、可重建的。
- 进程是故障边界，不是领域名词。
- Signal 表达发生了什么；Admission 决定谁应该看见。
- Agent 可以处理但不回应。
- Capability 是受治理能力，不是裸 tool call。
- Intent 先于 Effect。
- 重要行为必须可审计、可解释、可恢复。
- 记忆应通过推理与整合演化，而不是堆积为无结构日志。

## 开发

**前置条件：** Elixir 1.19+、PostgreSQL、Bun

确保 PostgreSQL 正在运行，并且 `.env.dev` 或 `.env.local` 中的 `DATABASE_URL` 指向可用数据库。

```sh
# 初始化 Elixir 依赖、JS 依赖、数据库和资产
bun setup

# 启动 Phoenix 和 Rsbuild 开发资源服务
bun dev
```

访问 `http://localhost:4000`。当前 app shell 会把 `/` 跳转到 `/setup`，该页面在此分支只是 placeholder。

开发模式下，Phoenix 会把 Rsbuild 作为 endpoint watcher 启动。浏览器入口仍然是 `http://localhost:4000`；Rsbuild 在 `http://localhost:5173` 为 React/Inertia 提供热更新。如果端口已被占用，可以在 `.env.local` 中设置 `PORT` 和 `RSBUILD_PORT`，例如 `PORT=4001`、`RSBUILD_PORT=5174`。

常用项目命令：

```sh
# 安装/更新 JS 依赖
bun install

# 运行提交前完整检查
bun precommit

# 运行前端测试和跨语言 lint 检查
bun run test
bun run lint
```

## Rsbuild 资产构建

React/Inertia 入口位于 `webui/src/app.jsx`，SPA 页面位于 `webui/src/apps/`。构建可部署资产时，Rsbuild 会写入 `priv/static/assets/.rsbuild/manifest.json`；非开发环境下，Phoenix 会从该 manifest 解析脚本与样式。

从仓库根目录运行 Bun；Rsbuild 使用 `webui/src/` 存放应用源码，使用 `assets/css/` 存放 Phoenix CSS 入口。

```sh
# 构建 Rsbuild 资产和 manifest
mix assets.build

# 构建生产资产并生成 digest
mix assets.deploy
```

`mix assets.deploy` 会执行编译、Rsbuild build 和 `phx.digest`。构建生产 release 前先运行它。

**生产环境：**

```sh
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
_build/prod/rel/bullx/bin/bullx start
```

## 环境文件

BullX 会从仓库根目录加载 dotenv 文件。后加载的文件覆盖先加载的文件；已经存在的 OS 环境变量优先级高于 dotenv 文件中的值。

| 环境 | 加载顺序 |
|---|---|
| 开发 | `.env` -> `.env.dev` -> `.env.local` |
| 测试 | `.env` -> `.env.test` |
| 生产 | `.env` -> `.env.prod` |

`.env.local` 已加入 `.gitignore`，用于存放机器专属的密钥。`.env`、`.env.dev` 和 `.env.test` 可作为团队共享的非密钥默认值提交到版本控制。
