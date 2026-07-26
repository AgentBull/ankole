---
title: 成本管理
description: 控制 Ankole 花费的杠杆——model profile 档位、reasoning effort、web 工具按需、agent 循环预算、后台任务重试与槽位上限。
section: Guides
order: 314
---

Ankole 花的大部分是模型 token，而其中大部分由一小撮配置杠杆决定，不是你无法塑造的用量。本页命名这些杠杆，说明各自的花费与节省，并给出账单太高时拉它们的顺序。这里的每一样都是控制面里真实的旋钮；没有一条是"少用 agent"。

先把决定性的性质说清楚：成本是*哪个模型跑、跑几次、跑多久*的函数。杠杆映射到这三件：model profile 档位选模型、agent 循环预算限迭代、任务重试与槽位上限约束失控情形。拉动那个匹配花费所在之处的。

## 杠杆 1：model profile 档位

十个 profile 槽是最大的杠杆。每个槽是一次模型选择，而模型选择主导 token 成本。

| 槽 | 何时跑 | 成本杠杆 |
|---|---|---|
| `primary` | 主推理模型——大多数回合 | 单条最大的成本项 |
| `light` | 高频低风险路径 | 应当真正廉价 |
| `heavy` | 硬综合 | 昂贵；`primary` 调好时很少用到 |
| 后台 Agent 任务（内部键为 `coding`） | 每个后台 Agent 任务 | 决定持久后台任务使用哪个模型或订阅账号 |
| `vision_fallback` | `primary` 处理不了图像时 | 仅在 agent 看图像时绑 |
| `embedding`、`rerank` | 记忆与检索 | 按调用计价，通常小 |
| `web_search`、`web_fetch` | web 工具 | 见杠杆 3 |
| `image_generate` | 图像生成 | 按次昂贵；仅在用时绑 |

两招最省：

- **把 `light` 绑到真正廉价的东西。** 它为高频路径而存在；一个几乎和 `primary` 一样贵的 `light` 让这个槽失去意义。
- **默认把 `primary` 调低、不调高。** 一个"感觉贵"的 agent，常常是 `primary` 相对于它实际做的工作绑得太重。质量需要时才上调。

Agent 用不到 `vision_fallback` 或 `image_generate` 时，可以把它们留空，避免产生相应调用。后台 Agent 任务不同：即使不单独配置，任务仍会回退到该 Agent 的 `heavy` 档案并通过 AIGateway 运行。只有在后台任务需要不同模型或指定的 ChatGPT 订阅账号时，才需要单独配置。

## 杠杆 2：reasoning effort

对 Codex 支持的 primary profile，`model_reasoning_effort` 是一档七级的旋钮：`minimal | low | medium | high | xhigh | max | ultra`。更低 effort 更廉价更快；更高 effort 在难题上更好、花费更多。默认 `high`。

这是比换模型更细的杠杆。一个在 `medium` 就够、却配成 `high` 的 `primary` agent，多花钱却无可见收益。在 `primary` profile 上设它，匹配 agent 的实际工作；只给那个做硬综合的 agent 上调，不是给所有 agent。

## 杠杆 3：web 工具，按需

`web_search` 和 `web_fetch` 是独立的 profile，每次调用都花钱。两招：

- **agent 不需要联网时解绑它们。** 一个纯内部助手不该绑 `web_search`；这个槽存在就是一张调用的许可。
- **知道 URL 时优先 `web_fetch` 而非 `web_search`。** 抓已知来源是一次调用；搜索是一次调用加 agent 决定做的若干次抓取。

`worker.rendered_fetch_idle_ttl_ms` AppConfigure 键控制渲染后的抓取结果缓存多久——更高的 TTL 节省同一 URL 的重复抓取，代价是陈旧。

## 杠杆 4：agent 循环预算

三个 AppConfigure 键限制每回合花费：

| 键 | 限制什么 |
|---|---|
| `ai_agent.max_iterations` | agent 循环每回合的迭代预算 |
| `ai_agent.max_output_tokens` | 每回合输出 token 上限 |
| `ai_agent.inactivity_timeout_ms` | 回合可 inactive 多久后被回收 |

`max_iterations` 限制单个 Agent 回合的模型迭代次数，避免本可用两次工具调用完成的任务反复调用模型。`max_output_tokens` 限制单次响应大小。两项都是实例级默认值，应按常见回合设置；复杂回合达到上限时，Agent 会基于已有内容给出最终回答。

## 杠杆 5：后台任务重试与槽位上限

后台任务能在重试上花 token，上限就是杠杆：

| 上限 | 值 | 效果 |
|---|---|---|
| `max_execution_attempts` | 5 | 任务在 `failed` 前最多重试五次 |
| `max_consecutive_turn_failures` | 5 | 连续回合失败后任务放弃 |
| `max_running_per_agent` | 3 | 每个 agent 最多三个运行中任务 |
| 重试延迟 | ~30 秒 | 重试之间的下限 |
| `agent_computer.background_agent_job.max_turns_per_worker` | 可配置 | 每个任务的 worker 回合上限 |

一个任务临时失败五次，就花五次运行的 token。多数时候上限保护你——配置错误快速失败并保持失败。要盯的是第三个：一个有三个并发任务的 agent 在同时跑三个模型循环。若不需要这种并行，人设（"一次只做一件事"）比上限允许的更便宜。

## 花费到底在哪

调整模型或并发之前，先在 Console 找到产生调用的 Agent、会话或后台任务：

- `GET /ai-gateway/conversations` 显示近期回合做过的模型调用——哪些 profile 解析了、多少次调用、哪些 provider。这是看花费是在 `primary`（量）、`heavy`（少数昂贵调用）、还是 `web_search`（许多小调用）的最快途径。
- `GET /background-agent-jobs` 显示任务 `attempts`——一个 `attempts: 5` 的任务花了五次运行。
- 结构化控制面日志带着 provider 调用的事件名和字段；你的日志摄入器可按 provider 和 agent 聚合。

修复从不是"少用 agent"，而是"这个具体杠杆对这个 agent 的工作设错了"。

## 一个完整示例

一个实例的账单在一周内翻倍。会话界面显示 `primary` 调用量正常，但 `web_search` 调用增长了十倍：一个使用 `may_intervene` 的团队助理开始为每条频道消息执行搜索。应当修改 Agent 的角色要求，例如“只在有人询问事实时搜索”，而不是调整全局成本限制。账单只反映问题，是否搜索仍由 Agent 的角色要求决定。

这是模式：成本问题常常是伪装的行为问题，行为杠杆是人设或 binding 策略，不是 token 上限。

## 成本管理不是什么

它不是实时花费仪表盘——Ankole 不输出。它不是把花费限制在某个美元金额的方式；杠杆限制*调用与迭代*，美元金额是 provider 费率乘以它们。它也不是读会话界面的替代；杠杆只有在你知道哪个设错之后才值得拉。

## 下一步

- Agent 的模型档案，读 [Agent](../agents/#接上它的模型)。
- agent 循环旋钮及其键，读[环境变量](../environment-variables/)。
- 相关会话与后台任务接口，读 [Console API 参考](../console-api/)。
- 任务上限，读[后台 Agent 任务](../background-jobs/)。
