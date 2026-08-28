---
name: applied-reading
description: Read a book or long text against stored memory and produce an applied analysis — a whole-life mirror that maps each chapter onto the reader's own situations and words, or a problem-lens playbook of moves to use, avoid, and watch for. Not a generic book summary.
tags:
  - mirror this book
  - apply this book to my life
  - strategic reading
  - read through the lens of my problem
  - personalized book analysis
  - 读书应用
  - 个性化解读
  - 带着问题读
brain-recall-only: true
ankole-runtime: any
---

# Applied reading

Take a text plus the reader, produce analysis that maps the text onto the
reader's actual life or problem. This is reading with a mission, not
summarization. If the person wants a plain summary, give them one without
this method.

## Pick the lens first

- **Mirror** — personalize the whole text to the reader's life. Each chapter
  gets two halves: what the author says, and what it reflects in the reader's
  own situations, people, and words.
- **Playbook** — read the text against one named problem. The output is
  tactics: what to do, what to avoid, what to watch for.

When the person names a problem, it is a Playbook; "how does this apply to
me" is a Mirror. Ask only when the request truly carries neither.

## Get the text and the context

- Pasted or short text: work in place.
- A book, PDF, or EPUB: create a Background Agent Job. The Job extracts
  chapter text with the `pdf` or `ocr` Skill, reads memory read-only through
  `recall` and `get_page`, and returns the analysis as its report.
- The reader context comes from memory, per section: generate targeted
  `recall` queries from what the author says in that section — the literal
  theme, the psychological parallel, a dated incident it maps to, the person
  in the reader's life it maps to, the period of their life it is closest to.
  Thin context produces a generic mirror; retrieve before you write.

## Mirror rules

- **The chapter half is the variety engine.** Preserve the author's stories,
  numbers, frameworks, and memorable phrases in enough detail that the reader
  could skip the book. A compressed chapter forces the mirror to repeat its
  greatest hits.
- **Observe, never prescribe.** The mirror points out parallels in the
  reader's own words and situations — "this is the same pattern as…" — and
  gets out of the way. No directives, no action items, no rearranging of the
  reader's life. Recognition is the win.
- **Anti-repetition is a hard constraint.** Assign each chapter a primary
  life domain and do not repeat a domain in adjacent chapters; cap any theme
  at three chapters; never reuse a story or quote across chapters; map at
  least a quarter of the chapters to joy, humor, or victory rather than
  wounds.
- **Honest misses.** When a chapter does not apply, say so plainly instead of
  forcing a connection.
- **Fact-check the reader.** Verify every factual claim about the reader's
  life against memory; remove what you cannot verify. A falsehood about the
  reader costs more than lost texture.
- **The editorial test.** Strip every citation: the mirror must still read as
  strong standalone writing that makes the reader feel seen, not studied.

## Playbook rules

- Triage sections by relevance to the problem; read the relevant ones deeply,
  skip the rest, and say which were skipped.
- Extract what the protagonists did, what worked, what failed, and what
  opponents did that was effective.
- Every recommendation cites its source moment; direct quotes carry more
  weight than paraphrase.
- End with recommendations at three horizons — now, this quarter, this
  year — each tied to source evidence.

## Deliver

The analysis goes to the reader as a message or a document. Memory is not the
delivery channel: `remember` a conclusion only when the reader asks to keep
it, and never auto-save the analysis.

## Anti-patterns

- A generic summary wearing a mirror's structure.
- Forced connections, invented reader backstory, or therapy homework.
- The same five themes recycled through every chapter.
- Recommendations without source evidence, or quotes that paraphrase.
- Skimming the text and mirroring only the reader profile.
