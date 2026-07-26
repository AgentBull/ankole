---
title: Let an Agent read images
description: Configure image understanding for an Agent and verify screenshots, photos, and charts from chat.
section: User guide
order: 42
---

A user can send a screenshot, photo, or chart to an Agent in chat. If the normal turn model cannot accept images, Ankole uses the model in the `vision_fallback` profile to read the image.

You can leave this profile empty when `primary` already supports image input. You can also leave it empty for an Agent that never receives images.

## Configure an image model

1. Open **Console → Agents** and select the Agent.
2. Find `vision_fallback` under **Model profiles**.
3. Select a Provider and model that explicitly support image input.
4. Save the profile, then start a new conversation.

The model list does not determine image support for you. Check the Provider documentation before you select a model.

## Verify the configuration

Send a clear image in a chat that is connected to the Agent. Ask a question that requires the image, for example:

> What error does this screenshot show? Tell me the most likely cause.

If the Agent ignores the image or says that it cannot read it, check these items in order:

1. The chat channel uploaded and forwarded the image.
2. `vision_fallback` is saved on the correct Agent.
3. The selected model supports image input.
4. The Provider credentials and quota are available.

To let an Agent create images, see [Image generation](../image-generation/). Image generation and image understanding use different model profiles.
