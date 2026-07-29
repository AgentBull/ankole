---
title: Background Agent Jobs
description: Delegate long work to a resumable background Job while the current conversation remains available.
section: User guide
order: 20
---

A Background Agent Job is for research, large file sets, document production, data analysis, repository changes, and other work that takes time. The Job runs independently in the background, so you can continue to talk to the Agent.

If you use <a href="https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/delegation.md" target="_blank" rel="noreferrer">Hermes Agent</a> or <a href="https://docs.openclaw.ai/subagents" target="_blank" rel="noreferrer">OpenClaw</a>, the nearest comparison is a subagent: the main Agent delegates independent work to another execution context.

Ankole calls it a Background Agent Job because the system stores work with a complete lifecycle, not a temporary call. A Job can recover after a Worker interruption.

The main Agent can send more information. Most Jobs return questions, failure states, and final results to the original conversation. A Job can also stay silent when you do not ask for an update, so you can inspect it later.

## Ask the Agent to create a Job

State the goal in chat and explicitly ask for background execution. For example:

```text
Run this as a Background Agent Job. Read these materials and prepare a decision
memo with evidence, disagreements, and open questions. Return the result here.
```

Provide the input files, completion criteria, and output format in the same request. State a deadline if one matters. The Agent decides how to perform the work, but a Job does not gain extra permissions because it runs in the background.

## Continue the conversation while the Job runs

After the Job starts, the main Agent can send more material, correct the request, or ask for its current state. A message can steer active work or resume a Job that waits for your answer.

In your request, state how you want the Agent and Job to work together:

- **Notify me when it finishes:** use this for work that can run independently. You can keep chatting while the result returns to the original conversation.
- **Research this in the background, then continue your answer:** use this when the current answer depends on the Job result.
- **Ask me before a key choice:** use this when direction or cost needs your decision. The Job pauses, asks in the original conversation, and resumes after your reply.
- **Run silently:** use this when the Job only needs to produce files or you plan to inspect it later. Tell the Agent not to send an update. You can ask about it later or inspect it in the Console.
- **Continue the previous Job:** identify the work and state the new requirement. The Agent can continue with its existing context when the Job is still resumable.

For example:

```text
Compare these three proposals in the background. Notify me when you finish.
Ask me here before you expand the scope or use a paid data source.
```

State whether the Job needs a repository, document set, or installed tool. The Agent selects a suitable workspace. You do not need to enter a workspace template ID or call a Job API.

## Select the model provider

Every Job uses AIGateway. When the Job is created, Ankole saves the effective **Background Agent Jobs** model profile. If that profile is empty, the Agent's `heavy` profile is the fallback.

To use a ChatGPT subscription, first create a [ChatGPT subscription provider](../chatgpt-subscription-provider/). Then open **Agents** in the Console, find **Background Agent Jobs** in the Agent's model profiles, and select that provider, an entitled model, the reasoning effort, and Fast Mode. The provider's credential pool selects and rotates accounts. The Job does not select an account.

## Inspect Jobs in the Console

Open **Background Agent Jobs**. The board groups Jobs into queued, active, and finished columns. Open a Job to see the original request, current plan, turn records, model usage, result, or error.

| Status | Meaning | What to do |
|---|---|---|
| `queued` | Accepted and waiting for an available Worker | Usually wait. Check Worker availability if it does not move. |
| `running` | Work is in progress | Open the Job to inspect the plan and latest progress. |
| `waiting_on_user` | Waiting for your answer or approval | Reply in the conversation that created the Job. |
| `succeeded` | Finished | Read the result. If you requested an update, confirm that the original conversation received it. |
| `failed` | Could not finish | Read the error. Correct the input or configuration, and ask the Agent to create a new Job. |
| `stopped` | Cancelled | The Job will not continue. |

`waiting_on_user` is not a failure. The Job releases its running capacity and resumes after you reply in the original conversation. Do not answer in an unrelated conversation because the Job cannot associate that reply with its question.

## Cancel a Job

Open the Job and select **Cancel**. A turn that has already started can take a short time to stop, so the status might not change to `stopped` immediately.

Cancellation does not remove files or execution records that the Job already produced.

If you only need to correct the goal, first tell the Agent in the original conversation. Cancel and create a new Job when the current one is going in the wrong direction, consumes resources, or is no longer needed.

## Common problems

- **The Job remains `queued`:** confirm that at least one Worker is ready and that other Jobs are not using all available capacity.
- **It fails as soon as it starts:** check the saved Background Agent Jobs model profile and the selected provider's credential-pool status.
- **It is `waiting_on_user`, but no question arrived:** check the signal routing rule and Channel Provider for the original conversation.
- **It succeeded but did not return to chat:** first confirm that it was not asked to stay silent. If it was not, open the Job and confirm that it has a result, then check the original conversation's routing rule.
- **An old Job ignores a model-profile change:** the provider binding is fixed when the Job is created. A profile change affects only new Jobs.
