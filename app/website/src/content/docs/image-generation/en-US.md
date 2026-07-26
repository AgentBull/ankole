---
title: Image generation
description: How image generation works — the image_generate profile slot, the ImageModelCatalog that validates endpoints, and why it is an internal AIGateway capability, not a tool the agent calls.
section: User guide
order: 39
---

Image generation is an AIGateway capability that produces images from a model prompt. It is not a tool the agent calls directly — it is composed into a Responses request by the hosted-tool preparation path, and the `image_generate` model profile slot controls which provider serves it. This page is the operator-facing view of that capability.

The decisive property, stated up front: image generation is **internal to AIGateway**. It is not exposed as a worker function tool. The agent does not call `image_generate` the way it calls `web_search` or `command`; instead, an image-generation request is composed into a Responses request when the hosted-tool path needs one, and AIGateway resolves it through the bound provider.

## The profile slot

The `image_generate` slot is one of the ten model profile slots, and it is optional. Only `primary`, `light`, and `heavy` are required; `image_generate` is bound only when the agent needs to generate images. Leave it unbound if no agent in the installation generates images — the slot existing is a license to use the capability.

See [Providers and models](../providers-and-models/) for how to bind the slot through the Console.

## The ImageModelCatalog

`ImageModelCatalog` is the definitive catalog of image-model endpoints and their capabilities. It is deliberately separate from language-model metadata, because image requests have their own fields — quality, background, and other parameters a text model does not use. The catalog validates that a provider endpoint can satisfy every requested field before the request is sent; an image request is rejected when no endpoint can satisfy the fields, not when the model returns an error.

The catalog has a one-hour cache, so the endpoint metadata is fresh enough to serve requests without re-fetching on every call, but not so stale that a provider's changed capabilities go unnoticed for long.

## What the operator does

- **Bind the `image_generate` profile** to a provider that serves image generation. Without the slot bound, the hosted-tool preparation path cannot compose an image request.
- **Do not expect a tool named `image_generate` in the agent's tool set.** The capability is internal; the model triggers it through the Responses composition, not through a function call.
- **Watch the cost.** Image generation is priced per image; an agent that generates many images per turn can spend quickly. The `image_generate` slot being unbound is the cheapest state.

## What this guide is not

It is not a prompt-engineering guide for image generation — the model's behavior within the Responses composition is the persona's concern. It is not a tool reference — there is no `image_generate` tool to document. And it is not a substitute for the provider's image-model documentation; the catalog validates capabilities, but the provider names the models and their fields.

## Next steps

- For the profile slots and how to bind them, read [Providers and models](../providers-and-models/).
- For the AIGateway boundary that serves image generation, read [AIGateway](../ai-gateway/).
- For cost awareness, read [Cost management](../cost-management/).
