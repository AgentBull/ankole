---
title: Let an Agent read images
description: Configure image understanding for an Agent and verify screenshots, photos, and charts from chat.
section: User guide
order: 42
---

Users can attach screenshots, photos, or charts directly in chat. Whenever the Agent's main language model does not accept image inputs natively, Ankole automatically routes image understanding through the model bound to `vision_fallback`.

Leave `vision_fallback` empty if the Agent's `primary` model already supports vision, or if the Agent never receives image attachments.

## Configure an image model

1. Open **Console → Agents** and select the target Agent.
2. Locate `vision_fallback` under **Model profiles**.
3. Choose a Provider and model that support image inputs.
4. Save the profile and start a new conversation.

Because the Console model selector does not filter models by vision capability automatically, check your Provider's documentation first to confirm that the chosen model accepts image inputs.

## Verify the configuration

Send a clear image in a chat channel connected to the Agent and ask a question that depends on reading the image—for example:

> What error does this screenshot show? Tell me the most likely cause.

If the Agent ignores the attachment or reports that it cannot view images, verify these four points in order:

1. The chat channel uploaded and forwarded the image attachment to Ankole.
2. `vision_fallback` is saved on the Agent handling that conversation.
3. The bound model genuinely supports image inputs.
4. The Provider's credentials are valid and have available quota.

To let an Agent generate or edit images rather than read them, configure `image_generate` instead; see [Image generation](../image-generation/).
