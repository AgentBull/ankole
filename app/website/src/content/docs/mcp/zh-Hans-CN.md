---
title: MCP server 参考
description: Skill-backed 与发布内置 Direct MCP 如何进入 Main、Background 和 Automation 执行。
section: Reference
order: 201
---

Ankole 有两种 MCP 接入方式。Skill-backed server 在 Skill 选好一个领域工具后，把 MCP 用作调用协议；发布内置的 Direct MCP server 则提供小型的模型可见工具面。

Skill MCP 依赖不会注册成模型原生工具，Agent 也不会直接收到它们的完整 MCP catalog。这样，Skill 是唯一的路由中心，不会出现第二套工具选择面。

## 声明依赖

在 Skill 的 `openai.yaml` 中，把 MCP 依赖写在 `dependencies.tools` 下：

```yaml
dependencies:
  tools:
    - type: mcp
      value: my-http-server
      description: "查询服务"
      transport: streamable_http
      url: https://mcp.example.com/mcp
      bearer_token_env_var: MCP_HTTP_TOKEN
      enabled_tools:
        - lookup

    - type: mcp
      value: my-stdio-server
      transport: stdio
      command: bunx --bun @example/mcp-server
      disabled_tools:
        - delete_record
```

一个 Skill 最多声明 64 个依赖。schema 是严格的：未知字段或属于另一种 transport 的字段会被拒绝。

### `streamable_http`

| 字段 | 含义 |
| --- | --- |
| `url` | HTTP 或 HTTPS server URL |
| `bearer_token_env_var` | 保存 bearer token 的环境变量名称 |
| `enabled_tools` | 可选的原始工具名 allowlist |
| `disabled_tools` | 可选的原始工具名 denylist |

token 值放在 Console 的[环境变量](../worker-env/)中。Skill 只保存变量名。

### `stdio`

| 字段 | 含义 |
| --- | --- |
| `command` | 启动 server 的受信命令行 |
| `enabled_tools` | 可选的原始工具名 allowlist |
| `disabled_tools` | 可选的原始工具名 denylist |

Agent Computer 通过 `/bin/sh -lc` 运行命令。stdio 只用于受信、第一方 server 命令。

声明不设置调用超时。Skill 或 Automation 脚本在每次 mcporter list 或 call 时传入 `--timeout`。

## 启用集合与冲突

一次执行获得当前已启用 Skills 的 MCP 依赖并集。两个 Skill 只有在连接、description 和 filters 完全相同时才能使用同一个 server 名；冲突会让执行准备失败。

`ankole-runtime` 控制哪个模型能读到 Skill。Main Agent 使用 `any` 和 `main` Skills；Background Agent Job 使用 `any` 和 `background_job` Skills。Automation Job 不运行模型，所以它读取当前全部 enabled Skills 的依赖，不按 `ankole-runtime` 过滤。

禁用一个 Skill 后，它的依赖会从下一次 turn、Background execution 或 Automation attempt 中消失。

## 生成 mcporter 配置

Agent Computer 为每次执行写一个唯一的 `0600` 配置，并把路径注入为 `MCPORTER_CONFIG`。配置总是包含 `imports: []`，所以 mcporter 不会合并 Agent Home、项目、Codex、编辑器或宿主机配置。执行结束时文件会被删除。

配置只包含连接事实和凭据变量名，不包含 WorkerEnv secret value。

Main Agent 通过 command tool 调用 mcporter；Background Agent Job 通过 Codex terminal 调用；Automation Job 在 `main.ts` 中用 `Bun.spawn` 调用。

## 发布内置 Direct MCP

Direct MCP server 随 Agent Computer Worker 发布，不来自 Agent 设置或 Skill。Main Agent 把它的工具作为 deferred Responses namespace 使用；Background Agent Job 把同一组工具作为 deferred Codex dynamic namespace 使用。

每个 Automation attempt 的按次 `MCPORTER_CONFIG` 也会包含全部 Direct MCP server。这保证能力一致，不表示平台预测脚本会使用它。Agent Computer 不增加运行时启用或禁用规则。生成配置不会启动 server；只有模型工具或脚本发起调用时才建立连接。

Flint Chart 是第一个 Direct MCP 集成。它通过 `bunx --bun --no-install` 使用 Worker 镜像中的 `flint-chart-mcp` 依赖，只暴露静态 PNG、SVG、Vega-Lite 编译与校验，默认 PNG，并禁用 Map 和 Choropleth。它不暴露 Flint MCP App。Direct MCP 注册是受信的发布合同，不是用户扩展面。

## 只选择并调用一个工具

Skill 必须先选择一个领域工具。只有需要当前 schema 时，才检查这个工具：

```bash
mcporter list 'my-http-server.lookup' --schema --json --timeout 360000
```

参数对象通过 stdin 传入，不要把 JSON 插值进 shell 文本：

```bash
mcporter call 'my-http-server.lookup' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

Automation 脚本使用同样的 argv，把 JSON 写入子进程 stdin，检查 exit code，然后解析 stdout。

## 安全边界

MCP output 是不可信输入。Skill 与 mcporter 路径不再提供 Ankole 旧原生路径的 output-schema 校验、MCP annotation 调度、tool-level approval UI，也不会按全部 WorkerEnv secrets 清洗结果。该路径用于受信、第一方 MCP Skills。远端 credential scope 仍是真正的读写权限边界。

Main 与 Background 的原生 Direct MCP 路径会校验 protocol result envelope 和声明的 output schema，限制结果，并只清洗该发布记录声明的 WorkerEnv 值。Automation 保留现有的脚本自管 mcporter 结果合同，不增加这层原生清洗。每个发布记录还必须定义自己的数据访问与产物合同。

## 下一步

- 编写 Skill 指引见[编写 Skill](../writing-a-skill/)。
- 配置 bearer token 见[环境变量](../worker-env/)。
- 使用已启用能力见[使用 MCP](../using-mcp/)。
