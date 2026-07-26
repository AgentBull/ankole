---
title: Run long research with Deep Research
description: Move multi-source research to a Background Agent Job and receive questions and the final report in chat.
section: Guides
order: 302
---

Deep Research is for literature reviews, competitor research, and multi-source fact checking. This work needs repeated search, reading, and cross-checking. The Agent can move it to a Background Agent Job and continue to handle your other messages.

## Before you start

Complete [Quick start](../quickstart/) and confirm that the Agent can reply in your chat channel. Configure the `web_search` and `web_fetch` model profiles when the Agent must search public web pages.

A Job can use an Ankole LLM Provider or a configured [ChatGPT subscription account](../codex-accounts/). Select the runtime in **Console → Agents → Background Agent Jobs**.

## Start the research

State the subject, time range, evidence rules, and output format. Ask for background execution:

```text
Run this as a Deep Research Background Agent Job.
Compare the pricing and product updates from these three vendors over the last
two quarters. Cite primary sources, separate facts from inference, and return
a report with links. Ask me before you expand the scope or use paid data.
```

A defined scope is more useful than “research this deeply.” State any primary-source rule, table requirement, or deadline in the same message.

## While the Job runs

The current chat remains available after the Agent creates the Job. You can keep talking to the Agent. You can also open **Console → Background Agent Jobs** to inspect the plan, progress, model use, and current status.

When the Job needs a decision, it asks in the original conversation. Reply there so it can continue. `waiting_on_user` means that the Job needs your answer. It is not a failure.

## Read the result

The Agent returns the result to the original conversation. Check that sources support the conclusions, the time range is correct, and facts are separate from inference. Ask the Agent to continue the same Job when you need more work.

If the Job fails or remains queued, open its details and read the status or error. See [Background Agent Jobs](../background-jobs/) for status meanings, cancellation, and runtime settings.
