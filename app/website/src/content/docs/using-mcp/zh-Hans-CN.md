---
title: 使用 MCP server
description: Ankole agent 如何把 Model Context Protocol server 当工具用——server 声明在哪、两种传输、默认超时、为什么 agent 只在声明它的 skill 启用时才看得到 server，以及运维如何改变 agent 看得到的 MCP server。
section: User guide
order: 35
---

Model Context Protocol（MCP）server 是 Ankole agent 在一个回合里调用外部工具服务的方式——一个查询 API、一个本地命令 server、一个托管的知识库。本页是 MCP 使用中的运维视角：server 对 agent 是什么、声明在哪、两种传输、agent 看得到的 server 集合怎么拼成。它是 [MCP server 参考](../mcp/)的使用侧配套。

先把决定性的性质说清楚：MCP server 不在 agent 层配置。它声明在 skill 的 `openai.yaml` 里，作为工具依赖；agent 看到的是它**已启用** skill 的 MCP server 的并集。没有单独的"agent MCP 配置"——skill 是唯一的注册源，所以开关 skill 就是你改变 agent 看到哪些 MCP server 的方式。

## server 对 agent 是什么

对 agent 来说，一个 MCP server 就是一组工具。模型在回合的工具集里看到这个 server 的工具，像调别的工具一样调它们，拿回结果。agent 不知道传输、URL 或命令——那些声明在 skill 里，不给模型看。`app/agent_computer/src/tools/mcp/` 里的 worker 配置负责加载声明、拉起 server、暴露它们的工具。

这跟 [Agent Library](../agent-library/) 别处用的投影模型一样：有效能力面是 agent 实际看得到的东西，由已启用的 skill 拼成，而不是运维得另管的第二套配置面。

## server 声明在哪

skill 在它的 `openai.yaml` 的 `dependencies.tools` 下声明 MCP 依赖。每条带 `type: mcp`、一个 `value`（server 名）、可选的 `description`、一个 `transport`，以及传输相关的字段。一个 skill 最多声明 64 条依赖。

```yaml
# skill 的 openai.yaml 内
dependencies:
  tools:
    - type: mcp
      value: my-http-server
      description: "Lookup tool"
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

一个回合跑起来时，Agent Computer 从每个已启用 skill 加载 MCP 声明，按 server 名去重，拉起 server。两个声明了同名 server 的 skill 贡献一个 server，两个 skill 都记为来源。

## 两种传输

一条 MCP 依赖是两种传输之一，schema 很严——属于一种的字段放到另一种上会被拒。

- **`streamable_http`**——通过 HTTP 访问的远程 server。带 `url`、`bearer_token_env_var`（一个环境变量的名字，其值作为 bearer token 发出）、可选的 `timeout_ms`。用于用 token 认证的托管 MCP server。token 本身绝不进 YAML——只放持有它的环境变量的名字，于是密钥留在 [WorkerEnv](../worker-env/) 里，不进 skill bundle。
- **`stdio`**——作为子进程拉起的本地 server。带 `command`（1–1024 字符）和可选的 `timeout_ms`。用于以可执行文件或 `npx` 风格包分发的 MCP server。server 作为 worker 的子进程跑，存活到本次回合的 MCP 用完为止。

## 超时

默认 MCP 超时是 360,000 ms（六分钟）。下限 100 ms。当某个 server 需要比默认更多或更少时，在依赖上设 `timeout_ms`。超过超时的工具调用会被取消，所以一个行为不端的 MCP server 拖不死一个回合。按 server 最坏的现实延迟挑超时，不要瞎猜——一个偶尔要 90 秒的 server 不该给 60 秒预算。

## 启用集怎么拼成

加载器读 agent **已启用**的每个 skill 的 `openai.yaml`——不是安装出厂的每个 skill。一个声明了但没在该 agent 上启用的 skill 不贡献 MCP server。启用一个声明了 MCP server 的 skill，那些 server 在 agent 下一个回合就可用；禁用它就把它们移走。

加载器从实际贡献每条声明的已启用 skill 元数据文件算出一个生成哈希，于是能判断集合何时发生实质变化、并按需重启 server。对运维的含义：MCP 面精确跟随 agent 的有效能力。"哪些 skill 开着"和"加载了哪些 MCP server"之间不会漂移。

## 如何改变 agent 看得到的 server

因为 skill 是唯一的注册源，运维的杠杆就是 skill 启用，走 [Agent Library](../agent-library/) 的 default-then-override 模型：

1. **增删一个 server**——改声明它的那个 skill。见 [Writing a skill](../writing-a-skill/)。
2. **为 agent 开一个 server**——启用声明它的 skill。一个 `default_enabled: true` 的内置 skill 已经把它的 server 贡献给每个 agent。
3. **为 agent 关一个 server**——收窄（禁用）声明它的 skill。

对需要 token 的 HTTP server，对应的环境变量必须在 [WorkerEnv](../worker-env/) 里设好；YAML 里的 `bearer_token_env_var` 只是名字，变量没设意味着这个 server 不带 token 认证，或者在调用时报错。

## 运维不该碰的东西

传输接线、server 起/停生命周期、按名去重，都是加载器的活，不是运维设的开关。server 名是 1–1024 字符、去首尾空白、无控制字符——它是模型看到的名字，也是加载器去重的键，所以一改名，模型对它的缓存认知就丢了；两个 skill 想指向同一个 server，必须用同名才会被合并。这些是写 skill 时要守的约束，不是运行时旋钮。

## 下一步

- 完整 schema、传输、加载器行为，读 [MCP server 参考](../mcp/)。
- 决定哪些 skill——进而哪些 MCP server——开着的目录与启用模型，读 [Agent Library](../agent-library/) 开发者页。
- 如何写一个声明 MCP 依赖的 skill，读 [Writing a skill](../writing-a-skill/)。
- `bearer_token_env_var` 解析到的环境变量，读 [worker 环境](../worker-env/)。
