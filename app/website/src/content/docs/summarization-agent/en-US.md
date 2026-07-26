---
title: Summarization agent
description: How to set up an agent that summarizes long documents — PDFs, transcripts, threads — into structured summaries, extracting key points, decisions, and open questions.
section: Guides
order: 340
---

A summarization agent takes a long document — a PDF, a meeting transcript, a channel thread, a research paper — and produces a structured summary: key points, decisions, open questions, and action items if applicable. This is one of the most direct uses of an LLM agent, and this guide is the practical shape of it in Ankole.

The decisive property, stated up front: the agent **summarizes faithfully, it does not editorialize**. It captures what the document says, organized into a useful structure, without adding opinions, omitting material facts, or hallucinating content that is not there. The summary is a projection of the source, not a replacement for it.

## What you need

- **`primary` profile bound** — summarization is a synthesis task that rewards a strong model.
- **A way to deliver the source document** — paste text in the channel, upload a file (through [worker files](../worker-files/)), or provide a URL (fetched through `web_fetch`).
- **A signal binding** to the channel where summaries post.

## The three input shapes

| Source | How it arrives | What the agent does |
|---|---|---|
| **Pasted text** | a long message in the channel | reads the text, summarizes |
| **Uploaded file** | a PDF, a Markdown file, a transcript | reads the file from Agent Home (through the shell or the `pdf` skill for PDF text extraction), summarizes |
| **URL** | a link to a web page or document | `web_fetch` reads the content, summarizes |

## The summary structure

A good summary the agent produces:

```text
**Summary — <source title>**
**Key points**:
- <point 1>
- <point 2>
- <point 3>
**Decisions** (if applicable):
- <what was decided>
**Open questions** (if applicable):
- <what was left unresolved>
**Length**: <original word count> → <summary word count>
```

The structure is consistent so the team knows what to expect. The persona can adjust the sections (add "risks" for a project doc, add "quotes" for a transcript).

## What the persona controls

- **Length** — "summarize in 200 words" vs "summarize in 5 bullet points" vs "one paragraph."
- **Structure** — the sections, the format (bullets vs prose), the level of detail.
- **Faithfulness** — "quote key passages verbatim; do not paraphrase critical statements."
- **Scope** — "summarize the whole document" vs "summarize only the section on X."

## A worked example

Set up an agent that summarizes PDF reports dropped in the channel:

1. Create the agent, bind `primary`/`light`/`heavy`.
2. Author `MISSION.md`: "When a PDF appears in the channel, read it through the pdf skill's text extraction. Produce a structured summary: key points (max 5), decisions, open questions. Quote any critical passage verbatim. Do not add opinions. Post the summary to the channel."
3. Upload a PDF through the worker-file routes (or paste a transcript).
4. The agent reads, extracts, structures, and posts the summary.

## Delegate long documents

For a very long document (100+ pages), the summarization itself can be slow. Delegate it to a background job (see [Delegation patterns](../delegate-patterns/)) — the job reads and summarizes; the agent posts the summary when the job completes. This keeps the conversation responsive.

## What this guide is not

It is not a search engine — the agent summarizes a specific document, not a topic across the web. It is not a fact-checker — it reports what the document says; verifying the document's claims is a different job. And it is not a replacement for reading the source — the summary is a projection; the source remains authoritative.

## Next steps

- For the pdf skill, read [PDF generation](../pdf-generation/).
- For the shell tools (text extraction), read [Code execution](../code-execution/).
- For delegation, read [Delegation patterns](../delegate-patterns/).
- For web fetch (URL sources), read [Web tools](../web-tools/).
