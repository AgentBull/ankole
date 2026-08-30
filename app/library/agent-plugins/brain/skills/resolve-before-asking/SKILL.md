---
name: resolve-before-asking
description: Use before you ask anyone who a person, company, or thing is, what role or relationship someone has, or before you present an entity as unknown. Exhaust memory first — entity, recall, get_page, synthesize — then external search, and escalate only with a hypothesis.
ankole-runtime: any
---

# Resolve before asking

Never ask "who is X?" when memory already answers. The memory answers before
the human is bothered — that is the product promise. Asking the user about an
entity whose page carries a role line, a timeline, and meeting history spends
their attention on a question the system can answer itself.

## When this fires

- A reply draft contains "who is [name]?" or an equivalent question.
- A draft asks about someone's role, relationship, or identity.
- You are about to present an entity as unknown or unidentified.
- You are composing a list of people and leaving any as "unknown".

## The lookup chain

Run in order. Stop at the first clear answer.

1. **This conversation.** The thread, its participants, and the channel often
   name the person already.
2. **`entity`.** The card returns the page, aliases, selected current facts,
   relations, and backlink count without a model call. A filled card is a
   resolved entity.
3. **`recall`, narrowed with `entity`.** Facts and takes come back first.
   Three timeline entries that repeat one role description settle the
   question.
4. **`get_page`.** Read the full page — body, current facts, timeline,
   links — before you conclude the memory does not know.
5. **`synthesize`.** Only when the answer needs threads connected across many
   pages; it is expensive. A clear synthesis answer ends the chain.
6. **External search.** Web or channel tools, seeded with the hints steps 1–5
   accumulated. `remember` what you confirm, with its provenance, so the next
   lookup does not repeat the work.
7. **Ask — with a hypothesis.** Only after all previous steps return nothing
   conclusive.

## Confidence

- **High — do not ask.** The entity card or synthesis gives a clear answer,
  or repeated timeline entries carry one consistent role.
- **Low — ask, leading with your best guess.** Signals are contradictory or
  very sparse. Open with the hypothesis, and state the contradiction when
  there is one.

There is no third state: either memory answered, or you finish the chain and
ask with a hypothesis.

## How to escalate

State what you searched, state what you found — partial signals included —
and ask one specific, confirmable question:

> Is Jane the operations lead at Acme? I find recurring invoice threads from
> @acme.example and two meetings alongside the Acme team, but nothing names
> her role directly.

Never a bare "who is Jane?".

## Email-domain shortcut

A sender's domain seeds the hypothesis; it is never proof.

| Domain shape | Hypothesis |
| --- | --- |
| Domain of a company memory knows | Likely an employee there. Confirm against the company page and shared history, then use it |
| Corporate domain memory does not know | A new company. Run the chain |
| Personal mail domain | No shortcut. Run the full chain |

## Anti-patterns

- "Who is X?" with no prior lookup.
- Asking about a relationship when the person's page holds a long timeline.
- Presenting a list of unknowns without running the chain on each name.
- Treating one recall hit as chain-complete: read the page before you
  conclude "not in memory".
- Escalating with false confidence: a partial signal is a hypothesis, not a
  resolution.

## The standard

Would the user look at this entity's memory — the timeline, the role facts,
the email domain that names an employer — and find it reasonable that you
asked? If not, the chain was not run. Run it.
