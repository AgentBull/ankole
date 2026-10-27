---
title: Image generation
description: Select an image model for an Agent and generate or edit images in chat.
section: User guide
order: 24
---

Enable image generation when an Agent needs to create illustrations, concept art, or visual drafts. Users stay in the same conversation, and the Agent returns each generated image as an attachment. When the selected model accepts reference images, the Agent can also edit an existing image in place.

## Select the execution path

The public `image_generation` tool supports two execution paths:

- **Hosted:** When you configure the Agent's `image_generate` profile, AIGateway executes the tool against that dedicated provider and model, then returns the resulting image to the main language model.
- **Native:** When you leave `image_generate` empty and use a main provider that declares native image generation (such as OpenAI or ChatGPT Subscription), AIGateway passes the public tool directly to that provider.

Because of this fallback behavior, the `image_generate` profile acts as a routing switch rather than an on/off toggle. If you leave `image_generate` empty and the main provider does not support native image generation, AIGateway rejects calls to the tool with a clear configuration error.

To configure the hosted path:

1. In **LLM Providers** in the Console, add a Provider that offers the image model you want to use.
2. Open **Agents** and select the target Agent.
3. Locate `image_generate` under its model profiles.
4. Select the image Provider and model, then save the profile.
5. Return to chat and send an image request to verify the setup.

AIGateway attributes language-model token usage to the main provider credential, while attributing image-generation usage to whichever credential actually generated the image—even after a credential-pool rotation.

## Write a short visual brief

Your prompt does not need to be long, as long as you tell the Agent where the image will be used, what it must show, and where it should not improvise. Lead with the purpose and main subject, then add only the composition, visual style, and constraints that matter for the final result.

Include any of these five elements when they help clarify the request:

- **Use and canvas:** Name the destination—such as a website hero, presentation slide, or social post—and specify landscape, portrait, square, or an exact aspect ratio.
- **Subject and scene:** Describe the main subject, its surroundings, and the action taking place.
- **Composition and visual language:** Specify only the viewpoint, placement, negative space, material, lighting, or medium that affects the outcome.
- **Text in the image:** Put exact text in quotation marks and state where it should appear. Keep longer copy outside the image whenever possible.
- **Constraints:** List any text, watermarks, logos, or objects that must not appear. When providing a reference image, also state which elements must stay unchanged.

For example:

```text
Use: A 16:9 hero image for a product announcement. The page title will be on the left.
Subject: A white device on a dark blue table, placed on the right.
Composition: Simple geometry, soft side light, and a large open area on the left.
Text: Include only "ANKOLE 2.0" in the bottom-right corner.
Constraints: No people, watermarks, other brand marks, or extra text.
```

Support for rendered text, output dimensions, and reference images varies across models, so check the documentation for your selected model and Provider.

## Refine the image in the same chat

You rarely need a finished image on the first try. Start by generating one visual direction, and then refine it incrementally in the same conversation. If you adjust one detail—or one closely related group of details—per turn, the result is much easier to steer without triggering a full redesign.

When asking for an edit, state both what to change and what to preserve:

```text
Change only the background to light gray. Keep the subject, composition,
lighting, text position, and colors unchanged.
```

If you attach multiple reference images, label them clearly (such as "Image 1" and "Image 2") and explain the role that each image plays—for example, taking the subject from Image 1 and the color palette from Image 2. Multi-image conditioning works only when the selected model supports reference images or editing.

## If no image appears

- **The Agent returns text only:** Confirm that the client or Agent exposes the `image_generation` tool, and check that either `image_generate` is configured or the main Provider supports native image generation.
- **No model is available:** None of your configured LLM Providers offers an image-generation model. Add a Provider that supports image generation.
- **The request is not supported:** Select a compatible model, or remove options that the current model does not support—such as a specific size, output format, transparent background, reference image, or edit instruction.
- **An image appears, but its content is wrong:** This usually reflects prompt ambiguity rather than a configuration fault. Reply in the same chat and specify both what to change and what to keep.
- **Generation succeeds, but no attachment appears in chat:** Confirm that the Channel Provider has permission to upload files, and inspect the delivery error logged for that conversation.

Supported sizes, file formats, transparent backgrounds, reference images, and editing features all depend on the underlying model and Provider.
