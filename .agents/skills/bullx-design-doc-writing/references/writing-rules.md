# Writing Rules For BullX Design Docs

Apply these rules during the edit pass. They are distilled from the referenced Google design-doc and technical-writing material, with BullX constraints applied.

## Source Basis

- https://www.industrialempathy.com/posts/design-docs-at-google/
- https://www.industrialempathy.com/posts/design-doc-a-design-doc/
- https://developers.google.com/tech-writing/one/just-enough-grammar
- https://developers.google.com/tech-writing/one/words
- https://developers.google.com/tech-writing/one/active-voice
- https://developers.google.com/tech-writing/one/clear-sentences
- https://developers.google.com/tech-writing/one/short-sentences
- https://developers.google.com/tech-writing/one/lists-and-tables
- https://developers.google.com/tech-writing/one/paragraphs
- https://developers.google.com/tech-writing/one/audience
- https://developers.google.com/tech-writing/one/documents
- https://developers.google.com/tech-writing/two/editing
- https://developers.google.com/tech-writing/two/large-docs
- https://developers.google.com/tech-writing/two/llms
- https://developers.google.com/tech-writing/one/summary
- https://developers.google.com/tech-writing/two/summary
- https://developers.google.com/style/highlights
- https://developers.google.com/style/accessibility
- https://developers.google.com/tech-writing/error-messages
- https://developers.google.com/tech-writing/error-messages/error-handling
- https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide
- https://developers.openai.com/codex/learn/best-practices
- https://google.github.io/eng-practices/review/
- https://basecamp.com/shapeup/1.5-chapter-06
- https://www.ap.org/media-center/press-releases/2024/new-ap-stylebook-includes-new-criminal-justice-chapter/
- https://medium.com/@alessandro.traversi/mastering-google-design-docs-a-comprehensive-guide-with-readme-md-template-a2706b57f64d

## Style Precedence

- Follow `AGENTS.md` and explicit user instructions first.
- Use this skill and BullX vocabulary next.
- Use Google Technical Writing and Google developer documentation style for general technical-writing rules.
- Use AP Stylebook only as a fallback for ordinary American English copyediting when BullX and Google guidance do not decide the issue.
- When AP conflicts with Google developer documentation style, prefer Google for BullX docs. For example, use the serial comma because Google developer docs require it.

## Design Doc Judgment

- Write a full design doc when the design is ambiguous, contentious, cross-cutting, expensive to reverse, or needs organizational memory.
- Prefer a mini design doc for incremental work that still has tradeoffs.
- Do not write an implementation manual disguised as a design doc. If no design choice exists, use an inline implementation plan.
- Keep requirements and design distinct. Requirements define what the system must do; the design doc explains how the software should satisfy those requirements and why that approach was chosen.
- Capture context and scope, goals and non-goals, the selected design, and cross-cutting concerns. Do not include alternatives or rejected options in the committed doc.
- State the degree of constraint when it affects the design. Greenfield designs need narrowing rules; constrained existing systems need explicit tradeoffs about how available pieces compose.
- Keep API and schema sketches at the level needed for the design decision. Avoid copying full interface definitions that will drift from code.
- Include code or pseudocode only when it explains a novel algorithm or non-obvious mechanism.
- Keep docs short enough to read. Split a large design into smaller docs when independent subproblems dominate the narrative.
- Update the design doc when implementation invalidates a design assumption before shipping.

## Shape Up Adaptation

- Borrow Shape Up only as a scope-control lens. Do not replace the Google-style design doc structure with a pitch template.
- Pair the problem with the proposed solution. A solution without a specific problem invites taste debates; a problem without a shaped solution pushes exploration into implementation.
- Include a baseline story when it helps judge solution fitness: what happens today, why that outcome is unacceptable, and how the proposed design changes the outcome.
- Use appetite as a constraint on complexity, blast radius, and implementation effort. Do not turn appetite into a calendar timeline, schedule promise, or estimate.
- Translate no-gos into `Non-Goals`. Name tempting but excluded functionality, use cases, compatibility paths, or abstractions.
- Translate rabbit holes into `Risks And Tradeoffs`. Bound details that could consume disproportionate effort or derail implementation.
- Prefer text-first shaping. Use diagrams and rough sketches only when they reduce ambiguity. Avoid high-fidelity mockups, screenshots, or prototypes unless the UI/interaction cannot be evaluated without them.
- Preserve implementation latitude. Do not over-specify visual layout, internal module shapes, or process topology beyond what the design decision requires.

## Reader Assumptions And Structure

- Assume the audience is BullX maintainers and Coding Agents unless the user names a narrower reader. Do not add a separate audience section by default.
- Assume senior engineering competence, but do not assume proximity to this subsystem.
- Start with the key decision and implementation surface. Include current-problem framing only when it changes how readers should interpret the design.
- Compare new ideas with existing BullX concepts or code paths.
- Use progressive disclosure: introduce concepts near the design detail that needs them.
- Prefer task- or decision-based headings over tool names when headings otherwise require insider knowledge.
- Add a short paragraph under each heading before the next subheading.
- Decide whether a large topic belongs in one design doc or in a set of smaller linked docs.
- Outline first when the scope is known. If the draft starts free-form, reorganize it before editing sentence-level style.

## Implementation Handoff For Codex And Humans

- Keep the doc readable for humans first, then add enough structure for Codex to execute reliably.
- Include `Goal`, `Context Pointers`, `Constraints`, `Tasks`, and `Done When` when the doc will guide implementation.
- Use `AGENTS.md` for durable repo rules and the design doc for task-local design decisions, tradeoffs, paths, tasks, and verification.
- Name exact files, modules, commands, examples, failing tests, logs, or external context sources when they matter.
- Break implementation work into ordered tasks that can be completed and reviewed independently.
- Include dependencies and per-task acceptance checks so Codex can avoid guessing task order.
- State the exact verification loop: tests to add or update, commands to run, diff review focus, and expected behavior.
- Keep ambiguity explicit. If a question changes behavior, persistence, security, or failure handling, state that Codex should stop and ask.
- Do not add agent-prompt boilerplate that tells Codex to chat through every step. The committed doc should be a plan artifact, not a transcript or prompt script.
- If external context changes frequently or lives outside the repo, name the MCP/tool/source Codex should use rather than pasting stale data into the doc.

## Words And Sentences

- Define unfamiliar BullX terms or link to the existing definition.
- Use one term for one concept. Do not alternate synonyms unless the distinction matters.
- Define acronyms only when the acronym is much shorter and appears many times.
- Replace ambiguous pronouns such as "it", "they", "this", and "that" with explicit nouns when more than one referent is plausible.
- Prefer active voice for responsibilities and decisions: name the actor, verb, and target.
- Use strong verbs. Replace vague verbs such as "occur", "happen", and unnecessary forms of "be" when a precise verb exists.
- Avoid opening sentences with "There is" or "There are" when a real subject and verb can do the work.
- Keep each sentence focused on one idea. Split long sentences or convert embedded lists to real lists.
- Remove filler phrases such as "provides a detailed description of" when a direct verb works.
- Prefer simple words, cultural neutrality, and direct English. Avoid idioms, marketing language, and rare words.
- Use standard American spelling and punctuation.
- Use second person only for direct instructions to the reader. Prefer neutral design statements for architecture and tradeoff sections.
- Put conditions before instructions when ordering affects execution.
- Avoid double negatives and "exceptions to exceptions."

## Formatting, Links, And Accessibility

- Use sentence case for headings.
- Use descriptive link text. Avoid "click here", "read this", or bare URLs when a named target is clearer.
- Put code-related text, commands, filenames, module names, functions, fields, env vars, and literal values in code font.
- Use bold only for UI elements or strong emphasis that materially improves scanning.
- Use unambiguous dates. Prefer exact dates when relative dates could confuse later readers.
- Do not rely only on color, position, size, or other visual cues to communicate meaning.
- Avoid directional references such as "above", "below", or "right-hand side"; use "preceding" and "following" instead.
- Provide alt text or adjacent explanatory text for diagrams and images. Do not present new information only in an image.
- Do not use screenshots of code, logs, or terminal output when text will do.

## Lists, Tables, Diagrams, And Paragraphs

- Use bulleted lists for unordered items and numbered lists for ordered steps.
- Start ordered implementation steps with imperative verbs when possible.
- Keep list items parallel in grammar, logical category, capitalization, and punctuation.
- Introduce each list or table with a sentence that explains what the reader is about to see.
- Use tables for compact comparisons. Keep cells short and column contents parallel.
- Use diagrams only when they reduce ambiguity. Constrain each diagram to one interaction, dependency graph, or failure path.
- Add a short caption or lead-in that states the diagram's takeaway before the reader sees it.
- Start each paragraph with the central point unless another structure clearly serves the reader better.
- Keep one topic per paragraph. Move or delete sentences that drift into another topic.
- Aim for three to five sentences per paragraph. Split paragraphs that become walls of text.
- Make important paragraphs answer what, why, and how.

## Code Samples And Examples

- Avoid code and pseudocode in design docs unless they explain a novel algorithm, API shape, query, state transition, or non-obvious boundary.
- When code is necessary, keep samples accurate, clear, short, and easy to understand.
- Prefer linking to existing code, experiments, or small proofs over copying large blocks that will drift.
- Add comments only where the sample's purpose is not obvious.
- Use examples and anti-examples when they clarify an important boundary or prevent a likely implementation mistake.

## Error And Failure Writing

- Error behavior should answer what went wrong and how the reader, user, operator, or system can fix or recover from it.
- Do not design silent failures.
- Avoid generic error text when the system can preserve useful cause information.
- Specify invalid inputs, violated constraints, missing permissions, provider failures, or unavailable dependencies when these distinctions affect behavior.
- Log or persist error codes and enough context for debugging, without exposing secrets or private data.
- Raise or report failures as early as useful so diagnosis stays close to the cause.

## Collaboration And Review

- Review design docs for design fit, functionality, complexity, tests, naming, comments, style, and documentation updates.
- Pick reviewers by ownership and correctness, not just availability.
- Split review responsibility by subsystem when one reviewer cannot evaluate all affected surfaces.
- Use canary readers before wide review when the design is still unstable. Prefer people close enough to find missing context and major soundness issues quickly.
- Ask for review on design choices while changes are still cheap. Do not wait until implementation has made a weak design expensive to change.
- Resolve comments by changing the doc, recording a deliberate tradeoff, or naming the remaining open question.
- During implementation, update the doc when reality changes the design before shipping. After shipping, link amendments or follow-up docs instead of pretending the original design always matched the final system.

## LLM And Editing Discipline

- Treat LLM output as a draft, not a source of truth.
- Provide source code, docs, and explicit audience context before asking an LLM to draft or revise a design doc.
- Ask for one bounded section at a time when the document is large.
- Verify factual claims against the repo before keeping them.
- Read the final document as the intended reader. Remove sections that do not satisfy the stated scope.
- Generate concise summaries by naming the summary's purpose, target audience, and style.

## Final Coverage Check

Before accepting `writing-rules.md` output or a generated design doc, confirm that the document answers the following:

- Does the opening state the key decision, scope, and reason to read?
- Are terms, acronyms, links, diagrams, lists, tables, code snippets, and dates styled consistently?
- Are goals, non-goals, and deliberate tradeoffs explicit enough for future maintenance?
- Are BullX invariants, persistence guarantees, failure behavior, security, privacy, governance, accessibility, and verification covered when relevant?
- If implementation will be driven from the doc, does the handoff identify context pointers, constraints, tasks, dependencies, done-when checks, and stop-and-ask conditions?
- Does every section justify its existence under the stated scope?
