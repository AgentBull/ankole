---
title: Background Agent Jobs
description: Delegate long work to a resumable background Job while the current conversation remains available.
section: User guide
order: 20
---

Use a Background Agent Job for sustained work such as research, large file sets, document production, data analysis, or repository changes. Because the Job runs independently in the background, your current conversation with the Agent stays free.

If you have used <a href="https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/delegation.md" target="_blank" rel="noreferrer">Hermes Agent</a> or <a href="https://docs.openclaw.ai/subagents" target="_blank" rel="noreferrer">OpenClaw</a>, the closest counterpart is a subagent: the main Agent delegates independent work to a separate execution context. Ankole models each delegated task as a durable, recoverable computation rather than an ephemeral call, so an interrupted Job resumes from its checkpoint across Worker replacements, crashes, or control-plane restarts.

While a Job runs, the main Agent can forward additional context or steer its work. By default, Jobs return clarifying questions, failure notices, and final results to the originating conversation, though a Job can also finish silently when you prefer to inspect its output later.

## Choose a Workflow or a Background Agent Job

Both features delegate work, but each fits a distinct work shape:

| Use | Choose it when |
|---|---|
| [Workflow](../workflows/) | The input is finite, tasks can run independently, and the stages are fixed before the run starts. It can fan out bounded checks in parallel and return one aggregate result. |
| Background Agent Job | One long task needs a persistent workspace, file or browser work, later messages, a question for you, or a resumable Codex thread. |

Unlike a Background Agent Job, a Workflow task cannot receive follow-up messages, spawn nested work, or maintain a persistent Job workspace. Choose a Background Agent Job whenever the task must adapt as new information arrives, and choose a Workflow when bounded parallel fanout is the primary goal.

## Ask the Agent to create a Job

State your goal in chat and explicitly ask the Agent to run it in the background:

```text
Run this as a Background Agent Job. Read these materials and prepare a decision
memo with evidence, disagreements, and open questions. Return the result here.
```

Include the input files, completion criteria, output format, and any deadline in the same prompt. While the Agent decides how to carry out the steps, delegating work to the background never grants extra permissions.

## Continue the conversation while the Job runs

Once the Job starts, you can ask the main Agent for its status, supply extra files, or refine the goal; your message can either steer active work or resume a Job paused for your answer.

Tell the Agent upfront how you want it to coordinate with the Job:

- **Notify me when it finishes:** best for independent tasks—keep chatting normally while the final result posts back to the originating conversation.
- **Research this in the background, then continue your answer:** best when the Agent's main reply depends on the Job's findings.
- **Ask me before a key choice:** best when scope or spend decisions need your sign-off—the Job pauses, asks in the originating conversation, and resumes once you reply.
- **Run silently:** best when the Job only produces files or you plan to review it later—ask the Agent not to post a completion message, and check on it later in chat or in the Console.
- **Continue the previous Job:** reference the earlier Job and state the follow-up requirement so the Agent resumes with the existing workspace and context when still resumable.

For example:

```text
Compare these three proposals in the background. Notify me when you finish.
Ask me here before you expand the scope or use a paid data source.
```

Mention whether the task needs a repository, document set, or installed tool, and the Agent will pick a matching workspace automatically—you never need to pass a workspace template ID or call a Job API directly.

## Select the model provider

Every Job routes model calls through AIGateway. When a Job is created, Ankole snapshots the Agent's effective **Background Agent Jobs** model profile, falling back to the Agent's `heavy` profile if **Background Agent Jobs** is left blank.

To run Jobs with a ChatGPT subscription, first configure a [ChatGPT subscription provider](../chatgpt-subscription-provider/), then open **Console → Agents**, locate **Background Agent Jobs** under the Agent's model profiles, and choose that provider along with an entitled model, reasoning effort, and Fast Mode. AIGateway's credential pool automatically selects and rotates accounts.

## Inspect Jobs in the Console

Open **Background Agent Jobs** in the Console, where the board groups Jobs into queued, active, and finished columns. Select any Job to inspect its original prompt, current plan, turn history, token usage, final output, or error details:

| Status | Meaning | What to do |
|---|---|---|
| `queued` | Accepted and waiting for the Agent's Worker or a free Job slot | Usually wait. If it does not move, check the Agent's Worker on **Console → Workers**. |
| `running` | Work is in progress | Open the Job to inspect the plan and latest progress. |
| `waiting_on_user` | Waiting for an answer from the Agent or from you | The Agent answers what it can. Reply in the conversation that created the Job when the Agent asks you. |
| `succeeded` | Finished | Read the result. If you requested an update, confirm that the original conversation received it. |
| `failed` | Could not finish | Read the error. Correct the input or configuration, and ask the Agent to create a new Job. |
| `stopped` | Cancelled | The Job will not continue. |

`waiting_on_user` is a normal pause rather than an error: the foreground Agent answers a Job's question directly whenever it already has the context, asking you only for human judgment, approval, or missing information. While paused, the Job frees its running slot and resumes once your reply arrives. Always reply in the originating conversation—messages sent in an unrelated thread cannot be matched to the paused Job.

## Cancel a Job

To stop a Job, open it in the Console and select **Cancel**. Because an active turn on a Worker may take a brief moment to wind down, the status may not switch to `stopped` instantaneously. Cancelling a Job preserves any files and execution records that it already produced.

If you only want to adjust the goal, message the Agent in the originating conversation first so it can steer the running Job; cancel and start a new Job only when the current run is heading in the wrong direction, consuming quota unnecessarily, or unneeded.

## Common problems

- **The Job stays `queued`:** check that the Agent's Worker is ready on **Console → Workers** and that sibling Jobs of the same Agent have not filled every running slot (`background_agent_jobs.max_running_per_agent`).
- **It fails immediately on start:** verify the Agent's **Background Agent Jobs** model profile and the bound provider's credential-pool health.
- **It sits in `waiting_on_user`, but no question appeared in chat:** check the signal routing rule and Channel Provider for the originating conversation.
- **It succeeded without posting back to chat:** confirm first that the prompt did not ask for silent execution; otherwise, open the Job to verify that a result was recorded and check the originating conversation's signal routing rule.
- **An admitted Job ignores a model-profile edit:** Ankole locks in the provider binding on a Job's first execution admission, so profile edits apply only to Jobs admitted afterward.
