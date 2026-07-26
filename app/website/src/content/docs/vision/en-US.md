---
title: Vision
description: How the vision_fallback profile slot works — when the agent falls back to a vision-capable model, and what the operator binds to make it available.
section: User guide
order: 42
---

Some turns carry images — a screenshot, a photo, a chart the agent needs to read. When the primary model cannot handle an image, AIGateway falls back to the model bound on the `vision_fallback` profile slot. This page is the operator-facing view of that fallback.

The decisive property, stated up front: `vision_fallback` is a **fallback, not the default image path**. If the primary model handles images natively, it processes them directly; `vision_fallback` is reached only when the primary cannot. An agent that never sees images does not need the slot bound — leave it empty and save the cost.

## The profile slot

`vision_fallback` is one of the ten model profile slots, and it is optional. Only `primary`, `light`, and `heavy` are required. The slot is bound to a model that handles images — typically a multimodal LLM from the same provider family or a dedicated vision model.

See [Providers and models](../providers-and-models/) for how to bind the slot.

## When the fallback triggers

The fallback is automatic. When a turn carries an image and the primary model's response indicates it cannot process it, AIGateway routes the image-bearing portion of the request to the `vision_fallback` model. The agent does not decide to fall back; the gateway detects the primary's limitation and routes. The agent sees the vision model's output the same way it sees the primary's — the fallback is transparent to the agent's loop.

## What to bind

- **Bind `vision_fallback` to a vision-capable model** when the agent handles images — a customer-support agent that reads screenshots, a research agent that processes charts, a QA agent that inspects UI renders.
- **Leave it unbound** when the agent never sees images. The slot existing does not cost anything until an image-bearing turn tries to fall back to it and finds no model bound — at which point the image is dropped and the agent continues without it.
- **Pick a model from the same provider family as `primary` when you can.** A vision model that speaks the same API reduces the risk of a format mismatch between the primary turn and the fallback.

## Cost awareness

Vision models are typically more expensive per token than text-only models. The fallback triggers only on image-bearing turns, so the cost is proportional to how often the agent sees images. An agent that occasionally gets a screenshot pays for the fallback only on those turns; an agent that processes images constantly should consider binding `primary` itself to a vision-capable model, so there is no fallback overhead at all.

See [Cost management](../cost-management/) for the profile-tier levers.

## What this guide is not

It is not a computer-vision tutorial — the model's ability to read an image is the provider's concern, not Ankole's. It is not a tool reference — there is no `vision` tool; the fallback is an AIGateway routing decision, not a function call. And it is not a substitute for the provider's vision-model documentation; the model names and their image capabilities are the provider's to document.

## Next steps

- For the profile slots and how to bind them, read [Providers and models](../providers-and-models/).
- For the AIGateway routing that does the fallback, read [AIGateway](../ai-gateway/).
- For cost awareness, read [Cost management](../cost-management/).
