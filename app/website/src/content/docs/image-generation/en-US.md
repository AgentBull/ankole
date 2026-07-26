---
title: Image generation
description: Select an image model for an Agent and generate or edit images in chat.
section: User guide
order: 22
---

Enable image generation when an Agent must make illustrations, concept art, or visual drafts. The user stays in the same chat, and the Agent returns each generated image as an attachment. If the selected model accepts reference images, the Agent can also edit an existing image.

## Enable image generation

1. In **LLM Providers** in the Console, add a Provider that supports image generation.
2. Open **Agents** and select the Agent that needs this capability.
3. Find `image_generate` in its model profiles.
4. Select an image-generation Provider and model, and save the profile.
5. Return to the chat and send the Agent a clear image request.

The `image_generate` profile is optional. Leave it empty for an Agent that does not need images. The Agent can still complete text, file, and other work.

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

- **The Agent returns text only:** confirm that its `image_generate` model profile is saved.
- **No model is available:** the current LLM Providers do not offer an image-generation model. Add a Provider that supports this capability.
- **The request is not supported:** select a compatible model, or remove an unsupported size, format, transparent-background, reference-image, or editing request.
- **An image appears, but its content is wrong:** this is usually not a setup fault. Continue in the same chat and state what to change and what to preserve.
- **Generation succeeds but the chat has no attachment:** confirm that the Channel Provider can still upload files and read the error for that conversation.

Available sizes, formats, transparent backgrounds, reference images, and editing features depend on the model and its Provider.
