---
name: brain-learning
description: Use when material or a thought must become durable memory, and when a remembered fact turns out wrong — learning an article, page, paper, book, file, recording, or meeting transcript; capturing someone's own idea; repairing memory after a correction. Read this before the first learn_source call in a conversation. Routes each material kind to the right learning path, guides the audience scope choice, and owns the write and repair discipline.
default_enabled: true
ankole-runtime: main
---

# Learning material into the Brain

`learn_source` registers one web address as a Brain learning source and starts
a background learning run: the system fetches the page, stores it as a memory
page, splits it for search, and extracts durable facts. The knowledge becomes
recallable for everyone inside its audience scope. You do not fetch, chunk, or
file anything yourself.

## Route the material first

| Material | Path |
| --- | --- |
| One public web page, article, paper, or post | `learn_source` with its url |
| Several specific pages | One `learn_source` call per url |
| A whole site, feed, or archive | Not supported as one action. Learn the specific pages that matter, or tell the user a site-wide import is not available yet |
| A book or local text file | Operator import: an admin registers a file source in the Console. Tell the user that, and name the file |
| A PDF, EPUB, or image | No direct learning path. A Background Agent Job with the `pdf` or `ocr` Skill extracts the text; then route the text — operator import for a durable source, `remember` for the few conclusions that matter |
| An audio or video recording | No learning path; the system does not transcribe. Ask for the transcript or notes, then route those as text |
| A meeting transcript or notes | Pasted into the conversation it is learned automatically; as a file it goes through operator import. `remember` each decision and commitment that matters, with the spoken words as provenance |
| Text pasted into this conversation | Nothing. Conversations are learned automatically; do not re-save them |
| Someone's own idea, thesis, or framework | `remember` — see "Capture ideas verbatim" |
| One fact, decision, or preference | `remember`, not `learn_source` |
| An open question that needs investigation and a report | A background job or deep research; afterwards `remember` the durable conclusions |

## Choose the audience scope

Omitting `scope` uses this conversation's audience: the asker in a DM, the
member group in a group chat. That default is right for most requests — the
person who asked can recall what was learned.

Pass `scope: "world"` only when both hold: the material is public, and the
requester wants the whole deployment to know it ("让大家都学一下" is world;
"帮我读一下这篇" is not). Pass a `group:<name>` scope to learn for one team
you belong to. When one request mixes audiences, learn the source at the
narrow scope and `remember` the shareable conclusions separately.

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
  company, or project, check `entity` first and attach the claim to the
  existing page; a name that does not resolve files the claim to the channel
  instead.
- Transcripts and recorder summaries carry claims, not facts. Transcription
  garbles names, and machine summaries turn banter into commitments. Before
  you remember a surprising claim — a role change, an ownership, a major
  event — find the words that state it, and `recall` what memory already
  holds. When the new claim contradicts established memory, do not overwrite;
  surface the conflict.
- A speaker or attribution you cannot resolve stays unwritten. A wrong
  attribution is worse than none.
- Learning is asynchronous. Do not describe or quote the material as learned
  in the same turn; say the learning run started. In a later turn, `recall`
  brings the content back.
- The same url registers once. Repeating the call reuses the source and
  re-runs learning, which picks up changed content. The reported
  `audience_scope` is the one that actually applies.
- A paywalled or login-walled page cannot be learned. Never work around an
  access wall; report the block and ask for an accessible copy.
- Never invent what a source contains. Before the learning run completes you
  know the url, not the content.

## Repair wrong memories

The direct fix is standing duty: `remember` the correction — a close match
supersedes the stale claim — otherwise `recall` the stale claim and `forget`
it by claim id. A wrong claim rarely lives alone, so after the direct fix:

- Check propagation. `recall` the wrong phrasing and its variants, and fix
  every claim that repeats the error, not the first one found.
- A fact attached to the wrong person has two homes to check: remove it where
  it does not belong, and record it where it does.
- A confabulation has no stored source to fix. `remember` the correction with
  the mistake named in `context`, so recall surfaces the guard next time.

## After it lands

Use `recall` or `get_page` to read the learned knowledge, `synthesize` when a
question needs conclusions drawn across many memories, and `remember` for your
own durable judgments about the material.
