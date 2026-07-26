---
title: 一个后台研究任务
description: 让 agent 把一项长研究任务委派给一个持久后台任务，从 Console 观察、回答它的问题、读取结果——而不占用会话回合。
section: Guides
order: 302
---

本指南覆盖一种塞不进一个回合的工作形态：文献扫描、竞品深挖、多来源综合，需要很多次工具调用。与其让人等，agent 把工作委派给一个**后台任务**——在会话之外运行的持久工作，完成或需要输入时回报，并熬得过 worker 丢失。

一句话讲完流程：**向 agent 要研究 → agent 派生任务 → 看任务运行 → 回答它的问题 → 读取结果。**

与[你的第一个 Lark 机器人](../lark-first-bot/)的重要区别：那里 agent 在一个回合里回答；这里 agent 在回合里*创建*一个后台 Agent 任务，任务自己跑。你在运维任务，不在运维会话。

## 你要建什么

一种委派模式，长这样：

1. **你请求** agent，在绑定的频道里，要一项长研究。
2. **agent 派生任务**，用它的 `create_background_job` 工具，带一个 `title` 和一个 `task`，并告诉你它已派生。
3. **任务运行**，在你的回合之外——很多次工具调用、很多次 web 抓取，需要几小时就几小时。
4. **任务回报**，当它完成（`background_agent_job.completed`）、失败（`…failed`）或需要人类决策（`…waiting`）时。
5. **你读取结果**，在频道里；或回答问题，让任务续接。

拥有任务的 agent 在任务跑的同时，仍然有空跟你说话。这就是要点：长工作不阻塞短问题。

## 前置条件

- 一套可用的 Ankole 部署，至少有一个 agent 和一个聊天 binding。还没有的话先做[你的第一个 Lark 机器人](../lark-first-bot/)。
- agent 的 `primary`、`light`、`heavy` model profile 已绑（必需槽，见 [Provider 与模型](../providers-and-models/)）。
- 若研究要抓取来源，agent 的 `web_search`、`web_fetch` profile 已绑。
- 一个已配置的 Codex account（见 [Console 运维操作](../console-operations/)）——后台任务跑在 Codex account 上，默认 `aigateway`。

## 第 1 步：请求研究

在绑定的频道里，向 agent 要一件真正耗时间的事。范围说清，否则任务会乱跑：

> 研究我们两个指定竞品最近两个季度的定价页和公开 changelog。总结变化，附链接。慢慢来——不必快。

"慢慢来"这个提示要紧：它向 agent 信号这是委派形态，不是快答。范围清晰的 prompt 产出范围清晰的 `task`。

## 第 2 步：看 agent 派生任务

agent 判断工作很长，调用 `create_background_job`，带一个 `title`（短、人可读）和一个 `task`（完整指令，从你的请求和人设推导）。若工作需要预备好的工作空间，它还会选一个 `workspace_template_id`。agent 在频道里回复说它已交接。

你不用自己调 `create_background_job`——它是 agent 的工具，不是你的。你的活是把请求范围说清；agent 的活是把它翻译成一个任务。

## 第 3 步：看任务运行

任务现在是持久状态。通过 Console 跟踪：

```bash
curl https://ankole.example.com/api/v1/background-agent-jobs \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

用 `GET /background-agent-jobs` 列出，用 `GET /background-agent-jobs/:job_id` 读取一个。任务流转 `queued` → `running` →（可选）`waiting_on_user` → `succeeded` 或 `failed`。各状态含义和重试预算（最多五次执行尝试、五次连续回合失败）见[后台任务（运维视角）](../background-jobs-ops/)。

`running` 中的任务占用 agent 的一个运行槽（每个 agent 最多三个）。它跑一会儿不必惊慌——研究本就该耗时，长时运行通常意味着模型在工作，而非卡住。

## 第 4 步：它问时回答

有些研究会撞上 agent 独自决定不了的问题——两个方向选哪个、某个来源是否权威、要不要多花时间。任务迁移到 `waiting_on_user`，释放运行槽，并向拥有它的 session 发回 `background_agent_job.waiting` 事件。问题落到绑定的频道。

在频道里回答。拥有它的回合用你的答案续接任务，任务迁回 `running`，继续。你不必去某个 console 里找到任务再填表——唤醒到达的地方，就是会话本来所在的地方。

## 第 5 步：读取结果

任务完成时，它发回一个带结果的 `background_agent_job.completed` 事件。在 agent 发帖的频道里读，或通过 `GET /background-agent-jobs/:job_id` 拉完整 `result` 字段。若结果不是你想要的，杠杆在原始 prompt 的范围和 agent 的人设——重新划定范围再问，而不是编辑任务。

任务失败时读 `error`。临时失败（provider 超时）会自动按预算重试；配置失败意味着 model profile 或 provider 凭证需要先处理，工作才能成功。

## 日常运维任务

- **取消失控任务**——`POST /background-agent-jobs/:job_id/cancel`。任务移到 `stopped`；进行中的回合被允许完成，然后取消才生效。
- **留意卡在 `queued`**——agent 可能已经有三个任务在跑。取消一个，或等一个完成。
- **续接 `waiting_on_user`**——在频道里回答；别让它一直等，它虽释放了运行槽，但在你的工作流里仍占着一个槽位。
- **让失败任务重试或失败到底**——别每次出错都手动重启；重试预算就是为临时失败而存在。

## 何时用任务，何时不用

后台任务适合长时、多步、或需要与会话隔离的工作。答案很短时不适合——为回答"现在几点？"派生一个任务，是只有开销没有收益的开销。agent 决定，但你的 prompt 划定决定：想要快答就要求快答，把"慢慢来"留给真正耗时的工作。

## 本指南不是什么

它不是写研究代码的教程——agent 用自己的工具做研究。它不是任何研究任务第一次就成功的保证；范围、人设、model profile 的质量决定这一点，你在几次运行里调它。它也不是运维界面的替代——完整状态词汇读[后台任务（运维视角）](../background-jobs-ops/)，生命周期内部读 [Background Agent Jobs](../background-agent-jobs/) 开发者页。

## 下一步

- 任务的运维视角，读[后台任务（运维视角）](../background-jobs-ops/)。
- 生命周期与恢复模型，读 [Background Agent Jobs](../background-agent-jobs/)。
- 研究任务所倚重的 model profile，读 [Provider 与模型](../providers-and-models/)。
