---
title: 编写 skill
description: 如何编写一个 skill bundle——SKILL.md frontmatter、agent 读取的散文、可选 MCP 依赖、agent 如何发现并使用 skill。
section: Developer guide
order: 114
---

skill 是一个文件系统 bundle，agent 在回合中读取它以学会做它原本不会的事。本页是贡献者 walkthrough：bundle 形态、让它可被发现的 frontmatter、让它有用的散文、声明 MCP 依赖的可选 `openai.yaml`。它建立在 [Agent Library](../agent-library/) 概念页之上；本页是*如何写一个 skill*。

先把决定性的性质说清楚：skill 是模型读取的散文，不是 worker 运行的代码。`SKILL.md` 就是 skill；其余一切（支撑文件、MCP 依赖、平台标签）都是那份散文的上下文。一个模型读了 `SKILL.md` 仍跟不上的 skill 是坏的 skill，无论它的支撑文件多好。

## bundle 形态

skill 是一个包含 `SKILL.md` 的目录，可选地有支撑文件和 `openai.yaml`：

```text
my-skill/
├── SKILL.md          # 必需——skill 本身
├── openai.yaml       # 可选——MCP 依赖和元数据
├── reference.md      # 可选——SKILL.md 引用的支撑文档
└── templates/        # 可选——skill 使用的文件
```

skill 名是目录名（小写，`[a-z][a-z0-9_-]{0,63}`）。skill 要么是 `builtin`（发布在 `app/library/skills`，同步进注册表），要么是 `installed`（agent 安装到 worker 可见存储下）。启用模型见 [Agent Library](../agent-library/)。

## SKILL.md frontmatter

`SKILL.md` 顶部是库读取用于发现和启用的 YAML frontmatter：

```yaml
---
name: my-skill
description: "一句话：agent 何时该用这个 skill。模型读它来决定。"
default_enabled: true
category: productivity
tags: [MyDomain, Automation]
ankole-runtime: background_job
license: MIT
platforms: [linux]
---
```

最要紧的字段：

- **`name`**——必须匹配目录名。注册表和 agent 用它寻址 skill。
- **`description`**——模型读取以决定是否使用 skill 的唯一字段。写成"当……时使用这个 skill"，触发条件要具体；模糊的描述是模型永远够不到的 skill。
- **`default_enabled`**——skill 是否默认对 agent 开启。运维者可按 agent 覆盖。
- **`ankole-runtime`**——若 skill 的工作需要后台任务的隔离（工具密集 skill 常见）写 `background_job`；在前台回合跑则省略。
- **`platforms`**——skill 的工具在哪些平台工作（`linux`，用于 Linux 专属工具的 skill）。需要 `pandoc` 的 skill 只在 `linux`；纯散文的 skill 平台无关。

`app/library/skills/` 里已有的 skill 是形态的最佳参考——写之前读几个。

## SKILL.md 正文

正文是 agent 使用 skill 时读取的散文。写给一个有能力但无背景的读者：模型会写代码和推理，但不知道你领域的约定。

一个有用的形态：

1. **skill 做什么**，一段。
2. **何时使用**——触发，比 frontmatter 描述展开。
3. **如何做任务**——步骤、工具、约定。这是 skill 的核心。
4. **不要做什么**——失败模式、护栏。

正文是 skill 成或败的地方。正文是通用建议（"小心"、"查文档"）的 skill 不比模型默认行为好；正文点出你领域确切的工具、命令和约定的 skill，才让 agent 做它没有 skill 就做不了的事。

## MCP 依赖（可选 `openai.yaml`）

若 skill 需要 MCP server，在 `openai.yaml` 的 `dependencies.tools` 下声明：

```yaml
dependencies:
  tools:
    - type: mcp
      value: my-mcp-server
      transport: streamable_http
      url: https://mcp.example.com/mcp
      bearer_token_env_var: MY_MCP_TOKEN
```

agent 只在声明它的 skill 启用时看到 MCP server 的工具。传输形态和"skill 作注册来源"的模型见 [MCP server 参考](../mcp/)。

## agent 如何发现并使用 skill

一个回合中，Agent Computer 读取已启用 skill 的 `SKILL.md` 文件并提供给模型。模型读 `description` 决定够哪个 skill，使用时读 skill 的正文。一个已启用但模型从不匹配其描述的 skill 是不可见的——把描述写成会被匹配的。

支撑文件（`reference.md`、`templates/`）在模型使用 skill 时可用，但模型按需读取，不默认读取。从 `SKILL.md` 正文按名引用它们（"读 `reference.md` 看完整 API"），让模型知道它们存在。

## 测试 skill

skill 靠使用来测：在 agent 上启用它、给 agent 一个 skill 覆盖的任务、读 agent 是否遵循 `SKILL.md`。agent 忽略某一步，那一步不够清晰；agent 从不够向 skill，描述没被匹配。改散文，不改机制——skill 就是散文。

## 本指南不是什么

它不是 prompt 工程教程——写给有能力的读者清晰散文，和写任何文档用同样的技巧。它不是跑任意代码的方式；skill 是散文和可选 MCP 依赖，模型调用的工具是 worker 的工具，不是 skill 的。它也不是读已有 skill 的替代；`app/library/skills/` 是形态的权威参考，读几个是写好一个的最快方式。

## 下一步

- 概念页（文件系统 bundle、启用、同步），读 [Agent Library](../agent-library/)。
- `openai.yaml` 里的 MCP 依赖，读 [MCP server 参考](../mcp/)。
- 启用 skill 的 `/agents/:agent_uid/library-capabilities` 路由，读 [Console API 参考](../console-api/)。
