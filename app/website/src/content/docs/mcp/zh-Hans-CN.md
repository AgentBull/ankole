---
title: MCP server 参考
description: 了解挂载在 Skill 下的 MCP 依赖如何注入主对话、后台任务与自动化任务。
section: Reference
order: 201
---

Ankole 将 MCP 封装在 Skill 背后以完成外部领域集成；平台既不维护 Agent 级别的全局 MCP 注册表，也不保存持久化的 `mcporter` 配置文件。

Skill 中声明的 MCP 依赖不会直接注册为模型原生工具，Agent 也不会直接收到完整的 MCP 工具目录。这样一来，Skill 始终是唯一的路由入口，不会衍生出第二套平行的工具选择面。

## 声明依赖

在 Skill 的 `openai.yaml` 中，将 MCP 依赖声明在 `dependencies.tools` 列表下：

```yaml
dependencies:
  tools:
    - type: mcp
      value: my-http-server
      description: "查询服务"
      transport: streamable_http
      url: https://mcp.example.com/mcp
      protocol_version: 2026-07-28
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

单个 Skill 最多可声明 64 项依赖。配置结构经过严格校验，任何未知字段或不属于当前传输模式的字段都会被直接拒绝。

### `streamable_http`

| 字段 | 含义 |
| --- | --- |
| `url` | HTTP 或 HTTPS 服务端地址 |
| `protocol_version` | 可选协议版本模式：`auto`、`legacy` 或 `2026-07-28`，默认为 `auto` |
| `bearer_token_env_var` | 存放 Bearer 令牌的环境变量名 |
| `enabled_tools` | 可选的原始工具名允许列表（白名单） |
| `disabled_tools` | 可选的原始工具名禁用列表（黑名单） |

仅当远端服务强制要求特定协议代际时，才需显式固定 `protocol_version`。实际的令牌明文应保存在 Console 的 [环境变量](../worker-env/) 中，Skill 配置里只记录变量名。

### `stdio`

| 字段 | 含义 |
| --- | --- |
| `command` | 启动本地 MCP 服务的受信任命令行 |
| `enabled_tools` | 可选的原始工具名允许列表（白名单） |
| `disabled_tools` | 可选的原始工具名禁用列表（黑名单） |

Agent Computer 会通过 `/bin/sh -lc` 执行该命令，因此 `stdio` 模式仅适用于受信任的第一方服务命令。

依赖声明中不设置调用超时，具体超时时间由 Skill 或自动化脚本在每次执行 `mcporter list` 或 `mcporter call` 时通过 `--timeout` 参数传入。

## 启用集合与冲突

每次执行时，运行时都会收集当前所有已启用 Skill 的 MCP 依赖并取并集。两个不同的 Skill 若要声明同一个服务名（`value`），其连接参数、`description` 与工具过滤规则必须完全一致；一旦出现不一致，执行准备阶段就会直接报错中止。

`ankole-runtime` 字段决定了哪类执行环境能够加载对应 Skill：主对话 Agent 会加载标记为 `any` 和 `main` 的 Skill，后台任务（Background Agent Job）加载 `any` 和 `background_job` 的 Skill；而自动化任务（Automation Job）不经过模型推理，因此会读取当前全部已启用 Skill 的依赖，不按 `ankole-runtime` 过滤。

禁用某个 Skill 后，其关联的 MCP 依赖会从下一回合、下一次后台任务执行或下一次自动化任务尝试起自动移除。

## 生成 mcporter 配置

每次启动执行时，Agent Computer 都会动态生成一份权限为 `0600` 的独立配置文件，并将其路径注入环境变量 `MCPORTER_CONFIG`。该配置文件始终带有 `imports: []`，从而阻止 `mcporter` 合并 Agent 主目录、项目目录、Codex、编辑器或宿主机上的外部配置；执行结束后，临时配置文件会立即销毁。

生成的配置文件中仅记录连接参数与凭证环境变量名，绝不写入 Worker 环境变量中的密钥明文。

在实际调用方式上，主对话 Agent 通过 `command` 工具执行 `mcporter`，后台任务通过 Codex 终端调用，自动化任务则在 `main.ts` 中使用 `Bun.spawn` 拉起子进程调用。

## 只选择并调用一个工具

Skill 应当先选定明确的目标领域工具；仅当确实需要查看最新参数结构时，才单独查询该工具的 Schema：

```bash
mcporter list 'my-http-server.lookup' --schema --json --timeout 360000
```

调用工具时，请通过标准输入（stdin）传入参数 JSON，切勿将 JSON 字符串直接拼接到 Shell 命令行中：

```bash
mcporter call 'my-http-server.lookup' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

自动化脚本遵循同样的参数约定：使用相同的命令行参数启动子进程，将参数 JSON 写入子进程标准输入，校验退出码后再解析标准输出。

## 安全边界

MCP 服务端返回的内容属于不可信外部输入。经由 Skill 与 `mcporter` 调用时，平台不会自动校验返回结果的 Schema、不会按 MCP 注解（annotation）拦截调度、不会弹出工具级人工审批确认，也不会自动从返回结果中脱敏 Worker 环境变量密钥。因此，该机制仅面向受信任的第一方 MCP Skill，远端服务凭证自身的权限范围（Scope）才是真正的读写安全边界。

## 下一步

- 了解如何编写 Skill，请参阅 [编写 Skill](../writing-a-skill/)。
- 了解如何配置 Bearer 令牌，请参阅 [环境变量](../worker-env/)。
- 了解如何在对话中使用已启用的 MCP 能力，请参阅 [使用 MCP](../using-mcp/)。
