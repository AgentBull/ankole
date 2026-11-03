---
name: brain-learning
description: Use when material, structured entity notes, or a thought must become durable memory, and when a remembered fact or page prose turns out wrong — learning an article, page, paper, book, file, recording, or meeting transcript; curating an entity, project, or concept page; capturing someone's own idea; repairing memory after a correction. Read this before the first knowledge-page write in a conversation. Routes each material kind to the right learning path, chooses a page with the intended audience, and owns the write and repair discipline.
default_enabled: true
ankole-runtime: main
---

# Learning material into the Brain

Pod knowledge pages hold the source text and curated notes. Brain retrieves
those pages, their relationships, and atomic claims. Save prose with the Pod
page tools and record a specific fact or judgment with `remember`.

## Route the material first

| Material | Path |
| --- | --- |
| One public web page, article, paper, or post | Read it with the available web tools, then save the relevant material and its source link in a knowledge page |
| Several specific pages | Read the pages that matter and save their evidence with clear source attribution |
| A whole site, feed, or archive | Select the specific pages that answer the request, or use a background research job to collect them; do not claim a site-wide import |
| A book or local text file | Read the text in a Background Agent Job, then save the requested material or conclusions in knowledge pages |
| A PDF, EPUB, or image | A Background Agent Job with the `pdf` or `ocr` Skill extracts the text; save the useful source material and `remember` the conclusions that matter |
| An audio or video recording | Use an available transcription tool; if none is available, ask for the transcript or notes and route those as text |
| A meeting transcript or notes | Read the transcript, then `remember` each decision and commitment that matters, with the spoken words as provenance; save a page when the person wants a durable document |
| Text pasted into this conversation | Conversations are learned automatically; do not duplicate the transcript merely to make it searchable |
| Someone's own idea, thesis, or framework | `remember` — see "Capture ideas verbatim" |
| One fact, decision, or preference | `remember` with `claim` and `provenance` |
| A structured page or dossier for a durable entity, project, or concept | Resolve the entity first; update its existing knowledge page, or use `write_object` with its installed Brain category |
| Revising or updating prose on an existing page | Read with `pod_get_page` at `level: "L2"`, then use `pod_save_page` with the returned `revision` as `base_revision` |
| An open question that needs investigation and a report | A background job or deep research; afterwards `remember` the durable conclusions or save the requested report in a knowledge page |

For a source that needs ongoing synchronization, an operator can register its
URL or file in the Console's Sources view. A one-time reading and page save
does not require source registration.

## Choose the page and its audience

Use `pod_list_pages` to find the destination. Omitting `id` lists the shared
Space roots; passing a page UUID lists its visible children. Use `brain` to
discover organizational knowledge and `write_object` to create or revise Brain objects. A new page inherits its parent's access. Choose the
existing team, entity, or conversation page whose readers match the request.
Public source material alone does not authorize sharing private analysis with
a wider audience.

For `remember`, omitting `source_node_id` uses the current conversation's
source page. Pass another source page UUID only when its audience fits the
claim. A claim's `entity` identifies its subject; `source_node_id` determines
who can retrieve its evidence. When a request mixes audiences, keep the
source material on the narrower page and record shareable conclusions on the
appropriate shared page.

## Capture ideas verbatim

A person's original thinking is the highest-value material, and their exact
wording is the signal. When someone states an idea, thesis, or framework worth
keeping — typed, spoken, or in a transcribed voice note:

- `remember` it with the person's own words in `provenance`, not a flattened
  paraphrase. The claim states the idea; the provenance quotes it.
- Choose the kind by nature: `belief` for a held position; `take`, `bet`, or
  `hunch` for a judgment or prediction, with the author as `holder`.
- One atomic claim per call. A voice note that covers an idea and a person
  becomes two claims.

## Write discipline

- Resolve the entity before you write. When a claim is about a named person,
  company, or project, check `entity` first and use the returned page UUID in
  `remember.entity`. Resolve ambiguity before attributing a claim.
- Read the whole page before changing it: `pod_get_page` takes `id` and
  `level: "L2"`, and returns `body`, `metadata`, `revision`, and visible
  children. Preserve unrelated prose and YAML frontmatter. Make the intended
  edit, then submit the complete Markdown through `pod_save_page` with `id`,
  `base_revision`, and `markdown`. A revision conflict means read again and
  reconcile the change.
- For a new Brain object, `write_object` takes `category`, `title`, and complete
  `markdown`. For a child of an existing knowledge object, `pod_create_page`
  takes `parent_id`, `title`, and complete `markdown`. Keep the returned `id` for later reads and writes. Link related
  pages using Markdown links whose target is `ankole:page/` followed by the
  actual page UUID, so graph traversal can follow their identities.
- Shared rules belong on their shared knowledge page. If the Agent cannot
  edit it, propose a `pod.knowledge.save` action card in a native Pod room,
  with the page ID, complete draft, and captured base revision. The owner
  reviews the diff before confirming. In external IM, provide the draft and
  page link for an authorized owner to review and save in Pod. For a new Brain
  object without creation permission, propose `brain.object.create` in a native
  Pod room with the category, title and complete Markdown draft.
- Transcripts and recorder summaries carry claims, not facts. Transcription
  garbles names, and machine summaries turn banter into commitments. Before
  remembering a surprising claim — a role change, an ownership, a major
  event — find the words that state it and `recall` what memory already
  holds. Surface a contradiction rather than silently choosing a version.
- A speaker or attribution you cannot resolve stays unwritten. A wrong
  attribution is worse than none.
- A successful page save confirms the document revision. Automatic fact
  extraction runs asynchronously; do not claim those facts have been learned
  until retrieval confirms them.
- If a source requires access you do not have, report the block and request
  an accessible copy. Never invent what the source contains.

## Repair wrong memories

Record the correction with `remember`, including the evidence and the
mistake in `context`. A matching stale claim can be superseded by the new
fact. Then check propagation:

- `recall` the wrong phrasing and its variants, and correct every repeated
  claim supported by the evidence.
- For a fact attached to the wrong person, inspect both people before
  recording the corrected attribution.
- If a stale structured claim remains active, identify it by claim ID for
  review in the Console; do not report it as removed.
- When wrong prose sits in a page, read its full content, correct the relevant
  span, and save the complete document under its captured `base_revision`.
  Preserve unrelated content and metadata.

## After it lands

Use `recall` for evidence and `pod_get_page` for the complete source page.
Use `entity` for current claims, timeline, relationships, and visible child
pages, and `synthesize` when a question needs evidence connected across many
memories. Record your durable judgments with `remember` and maintain curated
prose with the Pod page tools.
