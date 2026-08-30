---
name: scientific-research
description: "Use when the research task is a scientific, mathematical, or engineering question — physics, chemistry, biology, materials, quantitative methods — whose answer must be derived by computation, extracted from primary literature, or both."
---

# scientific-research — Derive, Then Cite the Primary Source

> A scientific answer rests on a reproducible derivation or a primary
> publication. A search snippet is neither.

## What this is

Method guidance for research whose subject is science or mathematics
itself: deriving a quantity, characterizing a mechanism, comparing
methods, or extracting established results from the literature. It
covers how to compute, which sources count as primary, and how exact a
scientific claim must be. To verify one specific claimed result — "does
the cited study really show X?" — use the `academic-verify` Playbook;
its database table (arXiv, Europe PMC, Crossref, OSF, …) applies here
too.

## Derive before you search

- A question that mathematics or a computation can settle is settled by
  computing it, not by searching for someone's answer. Formulate the
  problem in code: solve symbolically (sympy) where a closed form
  exists, then confirm numerically (scipy/numpy). Two independent
  routes to the same value — symbolic and numeric, or two different
  formulations — are what make a derivation verified.
- Test a conjecture by brute force on small cases before trusting it,
  and hunt for counter-examples with the same energy as confirmations.
- Record the derivation as a runnable script under the working
  directory, not as prose: the reader must be able to re-run it.
- When the literature search comes back empty, derivation from first
  principles is the fallback, stated as such with its assumptions.

## Primary literature

- Prefer the primary publication over reviews, textbooks, news, and
  encyclopedia summaries. Cite what the paper itself states; when only
  a secondary source is available, say so.
- Biomedical topics: PubMed/PMC serve full text for open-access
  articles; search there before general web search.
- Preprints: fetch the arXiv abstract page, not the PDF link; the
  abstract page carries version history and serves reliably.
- Paywalled papers: resolve the DOI and look for an open-access copy —
  PMC, the authors' institutional repository, or an OA locator —
  before treating the paper as unreadable.

## Exactness

- Name entities by their standard identifiers: IUPAC names, gene
  symbols, UniProt/PDB accessions, CAS numbers. A colloquial name is
  ambiguous evidence.
- A value carries its units and the conditions under which it holds —
  phase, temperature, concentration, model assumptions, dataset
  version. When several similar values exist in the literature, state
  which context yours comes from; a right number from the wrong
  context is a wrong answer.
- For mechanisms, pathways, and protocols, extract the complete chain —
  every intermediate, step, and state, with controls for experimental
  designs — not a summary of it. An incomplete mechanism is a finding
  gap; record it as one.

## Anti-patterns

- ❌ Searching the web for a value a ten-line script can compute from
  data or definitions already in hand.
- ❌ Citing a review or news article for a result the primary paper
  states — or worse, for a result it does not state.
- ❌ Reporting a value without units or conditions, or averaging values
  measured under different conditions.
- ❌ Declaring a derivation correct after one route; a single
  unconfirmed symbolic result is a hypothesis, not an answer.
