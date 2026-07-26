---
title: Translation agent
description: How to set up an agent that translates content between languages — preserving technical terms, maintaining tone, and delivering in the target language.
section: Guides
order: 341
---

A translation agent takes content in one language and produces a faithful rendering in another — preserving meaning, technical terms, and the source's tone. This guide is the practical shape of that agent, from setup to the translation loop.

The decisive property, stated up front: the agent **translates faithfully, it does not rewrite**. It preserves the source's structure, keeps technical terms and proper nouns in their accepted form, and matches the source's register (formal, casual, technical). The translation is a rendering, not an adaptation — unless the persona explicitly says to adapt.

## What you need

- **`primary` profile bound** — translation quality depends on the model's multilingual capability.
- **A signal binding** to the channel where translations arrive and depart.
- **The source content deliverable** — pasted text, an uploaded file, or a URL fetched through `web_fetch`.

## The workflow

1. **Source content arrives** — a message in the channel, an uploaded document, or a URL.
2. **The agent identifies the source language** — or accepts it from the request ("translate this from English to Japanese").
3. **The agent translates** — preserving structure (paragraphs, lists, headings), keeping technical terms and proper nouns in their accepted target-language form, matching tone.
4. **The agent delivers** — posts the translation to the channel, or writes it to a file.

## What the persona controls

- **Language pairs** — "translate between English and Chinese, English and Japanese." Name the pairs the agent handles.
- **Technical-term policy** — "keep code identifiers, API names, and product names in English; translate the surrounding prose." This is the most common policy for technical content.
- **Tone matching** — "match the source's tone. Do not formalize casual text or casualize formal text."
- **Format preservation** — "preserve Markdown formatting, code blocks, and link syntax."
- **Glossary** — "use the project's glossary for domain terms (stored as a Brain knowledge entry)."

## The glossary

For consistent translations across sessions, maintain a **glossary** as a Brain knowledge entry:

- Domain-specific terms and their accepted translations
- Product names that should not be translated
- Abbreviations and their expansions in both languages

The agent recalls the glossary during translation, so "deployment" always becomes the same word, not a different synonym each time.

## A worked example

Set up an agent that translates product docs between English and Chinese:

1. Create the agent, bind `primary`/`light`/`heavy` + `embedding` (for glossary recall).
2. Author `MISSION.md`: "Translate product documentation between English and Simplified Chinese. Keep code identifiers, API names, and product names in English. Match the source's tone. Preserve Markdown formatting. Use the project glossary from Brain for domain terms."
3. Curate Brain knowledge: the glossary entry (domain terms + accepted translations).
4. In the channel, paste or upload the source document.
5. The agent translates, preserving structure and terms, and posts the result.

## What this guide is not

It is not a localization service — the agent translates text; it does not adapt dates, currencies, legal disclaimers, or UI layouts. It is not a real-time interpreter — the agent works on documents, not on live conversation (though it can translate channel messages if asked). And it is not a substitute for a human reviewer on high-stakes translations — legal, medical, or brand-critical content still needs a human pass.

## Next steps

- For Brain knowledge (glossary), read [Brain](../brain/) and [Brain review](../brain-review-ops/).
- For file delivery, read [Worker files](../worker-files/).
- For web fetch (URL sources), read [Web tools](../web-tools/).
- For the summarization pattern (a related text-processing agent), read [Summarization agent](../summarization-agent/).
