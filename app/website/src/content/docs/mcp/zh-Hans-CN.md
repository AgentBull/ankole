---
title: MCP server 参考
description: Model Context Protocol server 如何声明与加载——openai.yaml 依赖模型、两种传输、超时，以及已启用 skill 如何贡献 server。
section: Reference
order: 201
---

Ankole agent 能在一个回合里把 Model Context Protocol（MCP）server 当工具调用。本页是 MCP server 如何声明、支持哪些传输、以及 agent 所见的 server 集合如何构建的参考。

先把决定性的性质说清楚：MCP server 不在 agent 层配置。它们在 skill 的 `openai.yaml` 里作为工具依赖声明，agent 看到的是它**已启用** skill 的 MCP server 并集。没有单独的“agent MCP 配置”文件——skill 是唯一的注册来源。

## server 在哪里声明

一个 skill 在它的 `openai.yaml` 元数据里的 `dependencies.tools` 下声明 MCP 依赖。每一项有 `type: mcp`、一个 `value`（server 名）、可选的 `description`、一个 `transport`，以及传输相关字段。一个 skill 最多声明 64 个依赖。

```yaml
# 在某个 skill 的 openai.yaml 里
dependencies:
  tools:
    - type: mcp
      value: my-http-server
      description: "查询工具"
      transport: streamable_http
      url: https://mcp.example.com/mcp
      bearer_token_env_var: MCP_HTTP_TOKEN
      timeout_ms: 60000
    - type: mcp
      value: my-stdio-server
      transport: stdio
      command: npx -y @example/mcp-server
      timeout_ms: 120000
```

一个回合跑起来时，Agent Computer Worker 从每一个已启用的 skill 加载 MCP 声明，按 server 名去重，并启动这些 server。声明同一个 server 名的两个 skill 贡献一个 server，两个 skill 都记为来源。

## 两种传输

MCP 依赖是两种传输之一，schema 严格——属于一种传输的字段在另一种上会被拒绝。

### `streamable_http`

经 HTTP 访问的远程 server。字段：

| 字段 | 含义 |
|---|---|
| `url` | server 的 HTTP URL（校验为 URL） |
| `bearer_token_env_var` | 一个环境变量的名字，其值作为 bearer token 发送 |
| `timeout_ms` | 可选请求超时 |

`streamable_http` 用于需要 token 的托管 MCP server。YAML 中只填写保存 token 的环境变量名称，token 本身留在 Console 的[环境变量](../worker-env/)中，不会写进 Skill。

### `stdio`

作为子进程启动的本地 server。字段：

| 字段 | 含义 |
|---|---|
| `command` | 启动 server 的命令行（1–1024 字符） |
| `timeout_ms` | 可选请求超时 |

`stdio` 用于以可执行文件或 `npx` 风格包分发的 MCP server。server 在回合使用 MCP 期间作为 worker 的子进程运行。

## 超时

默认 MCP 超时是 360,000 毫秒（六分钟），最小 100 毫秒。当某个 server 需要比默认值更多或更少的时间时，在依赖上设 `timeout_ms`。超过超时的工具调用会被取消，于是行为异常的 MCP server 不能无限拖住一个回合。

## server 名

server 名 1–1024 字符，去除首尾空白，不含控制字符。它是模型看到的键，也是加载器去重的键，所以一个稳定、可描述的名字要紧：重命名一个 server，模型会丢失对它的任何缓存理解；意图指向同一 server 的两个 skill 必须用同一个名字才会被合并。

## 启用集合如何构建

加载器读取 agent 已启用的每个 skill 的 `openai.yaml`——不是部署自带的每个 skill。声明但未在该 agent 上启用的 skill 不贡献 MCP server。启用一个声明了 MCP server 的 skill，让那些 server 在 agent 下一个回合可用；禁用它则移除它们。这让 MCP 界面成为 agent 有效能力的投影，而非一个运维者要单独管理的第二配置界面。

加载器为贡献每个声明的实际已启用 skill 元数据文件计算一个 generation 哈希，于是能判断集合何时发生了实质性变化，并按需重启 server。

## Ankole 里的 MCP 不是什么

它不是挂载任意长时服务的地方。MCP server 是回合调用的工具；它们按回合的节奏启动、回答、停止。它不是绕过权限边界的途径——agent 以自身身份、在自身权限下调用 MCP 工具。它也不按 agent 配置；skill 是注册来源，所以启用和禁用 skill 就是运维者改变 agent 所见 MCP server 集合的方式。

## 下一步

- 声明 MCP 依赖的 skill，读 [Agent Library](../agent-library/) 开发者页。
- 配置 `bearer_token_env_var` 所使用的值，读[环境变量](../worker-env/)。
- 在一个回合里跑 MCP 工具的 worker，读 [Agent Computer Worker](../agent-computer-worker/) 开发者页。
