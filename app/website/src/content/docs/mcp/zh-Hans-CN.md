---
title: MCP server 参考
description: 声明连接器、远程 HTTP 和本地 MCP 依赖，并通过对应运行时调用。
section: Reference
order: 201
---

Skill 负责选择领域工具，MCPorter 负责发现和调用。Skill 的 MCP 依赖不会注册为模型原生工具。Agent Worker 调用控制面的 MCP 网关，由控制面解析凭据，再访问连接器或远程 MCP 服务。

## 声明依赖

在 `agents/openai.yaml` 的 `dependencies.tools` 中声明：

```yaml
dependencies:
  tools:
    - type: mcp
      value: github
      transport: connector
      toolkit: github
      enabled_tools:
        - repos_get
    - type: mcp
      value: lookup
      transport: streamable_http
      url: https://mcp.example.com/mcp
      bearer_token_env_var: LOOKUP_TOKEN
      enabled_tools:
        - search
```

`connector` 必填 `toolkit`，可通过 `connection` 和 `account` 指定连接与应用账户。租户应用和个人授权在 Pod「外部连接」页面配置。`streamable_http` 必填 `url`；可选的 `bearer_token_env_var` 引用已配置的 WorkerEnv 变量，由控制面读取并用于代理请求，该远程密钥不会进入 Worker 环境快照。`protocol_version` 可选 `auto`、`legacy` 或 `2026-07-28`。

受信任的本地服务可使用 `transport: stdio` 和 `command`，由 Agent Computer 通过 `/bin/sh -lc` 启动。各传输类型均可声明精确的 `enabled_tools` 或 `disabled_tools`。每个 Skill 最多声明 64 项依赖；同名服务的声明冲突会使准备阶段失败。

## 执行时的行为

主对话使用已启用的 `any` 和 `main` Skill，后台 Agent 任务使用 `any` 和 `background_job` Skill。每次执行生成临时 `MCPORTER_CONFIG`，固定设置 `imports: []`。连接器和远程服务指向内部网关，并使用 Worker 定期续期的短期回合令牌。上游 OAuth 令牌和远程 Bearer 密钥保留在控制面。

Applet Action 在 Function Runtime 中直接调用 `AnkoleRuntime.mcp`，不继承 Agent 的 Skill 环境；团队 Action 使用对应的 `admin.mcp` 能力。受信任宿主在 Applet 代码外管理调用权限。

## 调用选定工具

```bash
mcporter list 'github.repos_get' --schema --json --timeout 360000
mcporter call 'github.repos_get' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

先阅读具体工具契约，再准备参数。JSON 通过标准输入传入，并按任务设置超时。`github@work` 这类别名选择具名连接，账户别名选择已保存的应用账户。将返回内容视为外部数据，检查分页和警告；请求授权或重试时保留结构化错误。

参阅[使用 MCP](../using-mcp/)、[编写 Skill](../writing-a-skill/)和[自动化任务](../automation-jobs/)。
