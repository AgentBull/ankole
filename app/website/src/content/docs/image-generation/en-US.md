---
title: Image generation
description: Select an image model for an Agent and generate or edit images in chat.
section: User guide
order: 24
---

Enable image generation when an Agent must make illustrations, concept art, or visual drafts. The user stays in the same chat, and the Agent returns each generated image as an attachment. If the selected model accepts reference images, the Agent can also edit an existing image.

## Select the execution path

The public `image_generation` tool has two execution paths:

- **Hosted:** configure the Agent's `image_generate` profile. AIGateway executes the tool with that separate provider and model, then returns the result to the main model.
- **Native:** leave `image_generate` empty and use a main provider that declares native image generation. OpenAI and ChatGPT Subscription support this path. AIGateway passes the public tool to that provider.

The `image_generate` profile is therefore a routing switch, not an enable switch. If the profile is empty and the main provider does not declare native image generation, AIGateway rejects the tool with a clear configuration error.

To use the hosted path:

1. In **LLM Providers** in the Console, add a Provider that supports the required image model.
2. Open **Agents** and select the Agent.
3. Find `image_generate` in its model profiles.
4. Select the image Provider and model, and save the profile.
5. Return to the chat and send a clear image request.

Model-token usage stays with the main provider credential. Image-token usage stays with the credential that generated the image, including after a pool rotation.

## Write a short visual brief

The request does not need to be long. Tell the Agent where the image will be used, what it must show, and where it must not improvise. Start with the purpose and subject. Then add only the composition, visual style, and constraints that affect the result.

Use these five parts when they are useful:

- **Use and canvas:** name the destination, such as a website, presentation, or social post. Give a landscape, portrait, square, or exact aspect ratio.
- **Subject and scene:** name the main subject, its surroundings, and the action.
- **Composition and visual language:** specify only the viewpoint, placement, negative space, material, light, or medium that matters.
- **Text in the image:** put the exact text in quotation marks and state its position. Keep long copy outside the image when possible.
- **Constraints:** name text, watermarks, logos, or objects that must not appear. For a reference image, also state what must remain unchanged.

For example:

```text
Use: A 16:9 hero image for a product announcement. The page title will be on the left.
Subject: A white device on a dark blue table, placed on the right.
Composition: Simple geometry, soft side light, and a large open area on the left.
Text: Include only "ANKOLE 2.0" in the bottom-right corner.
Constraints: No people, watermarks, other brand marks, or extra text.
```

Text, size, and reference-image support vary by model. Check the documentation for the selected model and its Provider.

## Refine the image in the same chat

An image rarely needs to be final on the first attempt. Generate one direction, and then make small changes in the same chat. Change one issue, or one related group of issues, in each turn. This makes the result easier to control and avoids a full rewrite.

For an edit, state both what to change and what to preserve. For example:

```text
Change only the background to light gray. Keep the subject, composition,
lighting, text position, and colors unchanged.
```

If you attach more than one reference image, label them as “Image 1” and “Image 2” and state the role of each image. For example, use the subject from Image 1 and the colors from Image 2. This works only when the selected model supports reference images or editing.

## If no image appears

- **The Agent returns text only:** confirm that the client or Agent exposes the `image_generation` tool. Then confirm that `image_generate` is configured or that the main Provider supports native image generation.
- **No model is available:** the current LLM Providers do not offer an image-generation model. Add a Provider that supports this capability.
- **The request is not supported:** select a compatible model, or remove an unsupported size, format, transparent-background, reference-image, or editing request.
- **An image appears, but its content is wrong:** this is usually not a setup fault. Continue in the same chat and state what to change and what to preserve.
- **Generation succeeds but the chat has no attachment:** confirm that the Channel Provider can still upload files and read the error for that conversation.

Available sizes, formats, transparent backgrounds, reference images, and editing features depend on the model and its Provider.
