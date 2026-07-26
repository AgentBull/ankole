---
title: 后台任务（运维视角）
description: 如何观察和取消一个 agent 的后台任务——状态含义、等待用户时的表现、重试预算，以及取消行为。
section: User guide
order: 20
---

一个后台任务是 agent 从自己回合里委派出去的工作——某件长时、隔离或步骤繁多的事。运维者不直接创建任务；agent 在回合里创建。你的职责是观察它们、理解各状态含义、并在需要时取消某个。本页是运维视角；生命周期的内部细节在 [Background Agent Jobs](../background-agent-jobs/) 开发者页。

先把决定性的性质说清楚：一个任务是持久工作，不是子进程。它的状态熬得过 worker 丢失，取消它也不会从一个正在跑的回合底下把 live worker 猛地抽走。

## 列出和读取任务

```bash
curl https://ankole.example.com/api/v1/background-agent-jobs \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

用 `GET /background-agent-jobs` 列出任务，用 `GET /background-agent-jobs/:job_id` 读取一个。一个任务带着它的 `title`、`task`、`status`、`attempts`、`result` 或 `error`，以及它回报回去的 `owner_session_id`。按 agent、按状态或按时间过滤列表，参数见 [Console API 参考](../console-api/)。

## 各状态含义

一个任务在六个状态间流转。运维者要采取行动的：

| 状态 | 含义 | 你做什么 |
|---|---|---|
| `queued` | 已接受，等待运行槽 | 通常什么都不做——槽一空就会启动 |
| `running` | 占用 agent 的一个运行槽（每个 agent 最多三个） | 观察；除非跑太久，否则无需动作 |
| `waiting_on_user` | 暂停等待人类输入；已释放它的槽 | 通过拥有它的 session 回答 agent 的问题；任务会续接 |
| `succeeded` | 终态；任务完成并已回报 | 读 `result` |
| `failed` | 终态；任务耗尽重试预算或遇到不可恢复错误 | 读 `error`；决定是否重跑 |
| `stopped` | 终态；被运维者取消 | 无需动作；任务不会再跑 |

`waiting_on_user` 值得停下来讲。它不是卡住——它在等一个人类决定，并且已经把运行槽还回去，让 agent 能做别的事。agent 的问题作为 `background_agent_job.waiting` 事件到达拥有它的 session；通过那个 session 回答，任务就续接。

## 重试预算

一个任务有一份有界的重试预算：最多**五次执行尝试**，最多**五次连续回合失败**。某次尝试没能干净启动时，运行时把任务放回 `queued` 再试一次，两次尝试之间有有界延迟（约 30 秒）。超出预算的任务落入 `failed`，原因在它的 `error` 里。所以一个 `failed` 的任务不是试了一次就放弃的——它是试满了预算仍没能成功的任务。

## 取消任务

```bash
curl -X POST https://ankole.example.com/api/v1/background-agent-jobs/<job_id>/cancel \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

取消把任务推到 `stopped`。它不会从一个正在跑的回合底下把 live worker 猛地抽走——回合自行结束或失败，受每一次 worker 写入都要经过的同一套校验约束。这就是为什么一个被取消的任务可能在落到 `stopped` 之前短暂显示 `running`：允许进行中的回合完成，然后取消才生效。

## 出问题的时候

- **一个任务长时间停在 `queued`**——agent 可能已经有三个任务在跑（按 agent 的槽上限）。取消一个正在跑的，或等一个结束。
- **一个任务 `running` 太久**——检查 agent 的 model profile 和上游 provider；长时运行的任务通常在等模型，不在等 Ankole。
- **一个任务进了 `failed`**——读 `error`。原因临时（provider 超时），agent 可以创建新任务；是配置错误，就先修配置。
- **`waiting_on_user` 但问题没到**——唤醒事件发往拥有它的 session；检查该 session 的 signal binding 已启用、channel 在范围内。

## 下一步

- 生命周期内部——状态机、唤醒事件、恢复模型——读 [Background Agent Jobs](../background-agent-jobs/)。
- 路由，读 [Console API 参考](../console-api/)。
- 任务在其内运行的回合，读 [Actor Runtime](../actor-runtime/) 开发者页。
