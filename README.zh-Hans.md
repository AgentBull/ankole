# BullX — 次世代 AgentOS

[![License](https://img.shields.io/badge/license-Apache%202.0-red.svg?logo=apache&label=License)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.19-48205D?logo=elixir)](https://elixir-lang.org)

[English](./README.md) | [简体中文](./README.zh-Hans.md) | [日本語](./README.ja.md)

> :warning: **BullX 目前处于早期开发阶段，预期会有显著变化与更新。**

**通用型 AgentOS——但在金融等严肃场景中具有独家优势。**

BullX 是一个高可用、自演化、自愈的 AI Agent 操作系统，基于 Elixir/OTP 和 PostgreSQL 构建，专为长时间运行的生产级 Agent 工作负载而设计。它的可靠性保证、持久化状态、可审计记忆以及人在回路的控制机制，在停机、成本失控、上下文丢失或静默故障会带来实际代价的场景中，价值最为显著。

## 核心能力

### 生产级运行时

延伸阅读：[在1986找到2026年多智能体编排的正确打开方式：为什么OTP是更好的运行时](https://ding.ee/zh-Hans-CN/why-otp-is-a-better-runtime-for-multi-agent-orchestration/) 解释了为什么 Elixir/OTP 是 BullX 设计的核心。

- **高可用**——基于 Elixir 与 Erlang/OTP 构建，这是一门电信级、容错的编程语言与运行时。监督树把进程调度、状态归属、故障隔离与重启恢复作为一等原语来处理，因此 BullX 能自动从故障中恢复，在部分组件宕机时仍保持运行。
- **基于 PostgreSQL 的持久化状态**——PostgreSQL 是 Session、记忆与知识的权威存储系统，开箱即得事务性写入、复制以及任意时点恢复——无需自建并演进任何私有的磁盘格式。
- **自愈**——单个 agent 进程可以崩溃而不影响系统其他部分；监督进程会将其重启到已知良好状态，故障被隔离在进程边界内。
- **为长时间运行的工作流而生**——BullX 专为需要跑几天甚至几周、而非几秒的 Agent 任务设计——深度研究、通宵回测、持续监控。定时任务与 Cron 风格作业以**精确一次（exactly-once）语义**跨重启、故障切换与崩溃执行，既不会静默丢失，也不会静默重复。

### 演化中的记忆与世界模型

- **自演化记忆**——记忆是推理循环，而不是日志。BullX 在每次交互中按不同的推理层级（直接观察、演绎、归纳、矛盾）提取结构化的记忆痕迹；与此同时，一个后台整合过程会合并冗余、检测新旧信念间的冲突，并把低层观察提升为更高层的模式。被取代的记忆采用软删除而非抹除，因此每一条结论都保留完整的溯源链，系统认知随时间的演化过程可被完整重建。
- **本体论驱动的知识图谱**——一套由实体、关系与属性构成的类型化本体论，构成 BullX 的世界模型。每个实体既是可沿关系遍历的图节点，同时也是其自身累积推理的容器，因此规划与回忆都建立在共享的领域 Schema 之上，而非散乱的文本片段。类型化的关系在提取阶段即为"幻觉关系"设立护栏。
- **多视角记忆**——一个真正类脑的记忆系统，必须反映心智的实际工作方式：同一实体不以一份共享的"客观"记录形式存在——它在每个观察者心中作为一个独立的内部表征而存在，由该观察者自身的交互历史所塑造。BullX 在数据层面直接映射这一原则。记忆按 (observer, observed) 对组织——每一对拥有各自独立演化的推理链——因此同一实体在不同视角下、甚至相互矛盾的认知可以并存、各自自洽，可按视角查询，而不会被强行融合成单一记录。

### 感知与意图

- **双通道感知**——两条输入通道汇入同一个推理层：与用户或其他 Agent 的对话，以及以**符合 CloudEvents 规范**的方式投递的外部事件触发（政策变动、市场波动、供应链扰动、财报发布、webhook 回调）。无论是否有人主动提起，BullX 都会对世界的变化作出反应——这对那些"信号不等人发问"的领域至关重要。
- **业务意图理解**——一个专门的层负责把进入的请求映射到业务本体论中的概念与目标上，因此 Agent 规划的依据是"用户想达成什么"，而不是字面上说了哪些词。

### 编排与控制

- **混合工作流编排**——可以把工作流组织为有限状态机、DAG 或行为树，节点可以是 LLM Agent、确定性代码或外部服务。LLM 本身也可以根据高层目标生成这些拓扑；拓扑一旦生成，工作流就以结构化图的形式执行，而不是 open-ended 的 Agentic 循环——每次运行的 token 消耗大幅降低、行为远为可预测和可复现，并且每个节点都在 OTP 监督下执行。让 LLM 只出现在真正需要思考的地方，其余部分交给编译后的图。
- **预算感知与人在回路**——每次工作流运行都会对照配置的预算跟踪成本。花费上限、权限闸门与审批步骤都可以暂停执行，在 Agent 采取昂贵或不可逆的动作之前把决策交给人类审查者——这让 BullX 可以安全地部署在受监管系统的工作流中。

## 快速上手

**前置条件：** Elixir 1.19+、PostgreSQL、Bun

确保 PostgreSQL 正在运行，并且 `.env.dev` 或 `.env.local` 中的 `DATABASE_URL` 指向可用数据库。

```sh
# 初始化 Elixir 依赖、JS 依赖、数据库和资产
bun setup

# 启动 Phoenix 和 Rsbuild 开发资源服务
bun dev
```

访问 `http://localhost:4000`。

当本地 `users` 表为空时，`/` 会跳转到 `/setup`。一旦至少存在一个用户，未登录用户会进入 `/sessions/new`，已登录用户访问 `/` 时会挂载控制台 SPA。

开发模式下，Phoenix 会把 Rsbuild 作为 endpoint watcher 启动。浏览器入口仍然是 `http://localhost:4000`；Rsbuild 在 `http://localhost:5173` 为 React/Inertia 提供热更新。
如果这些端口已被占用，可以在 `.env.local` 中设置 `PORT` 和 `RSBUILD_PORT`，例如 `PORT=4001`、`RSBUILD_PORT=5174`。

常用项目命令：

```sh
# 安装/更新 JS 依赖
bun install
```

```sh
# 运行提交前的完整项目检查
bun precommit
```

```sh
# 运行前端测试和跨语言 lint 检查
bun run test
bun run lint
```

## Rsbuild 资产构建

React/Inertia 入口位于 `webui/src/app.jsx`，各 SPA 页面位于 `webui/src/apps/`。构建可部署资产时，Rsbuild 会写入 `priv/static/assets/.rsbuild/manifest.json`；非开发环境下，Phoenix 会从该 manifest 解析脚本与样式。
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
| 开发 | `.env` → `.env.dev` → `.env.local` |
| 测试 | `.env` → `.env.test` |
| 生产 | `.env` → `.env.prod` |

> `.env.local` 已加入 `.gitignore`，用于存放机器专属的密钥。`.env`、`.env.dev` 和 `.env.test` 可作为团队共享的非密钥默认值提交到版本控制。
