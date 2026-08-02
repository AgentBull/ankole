---
name: academic-verify
description: "Use when the requested research deliverable verifies a specified academic claim, study, paper, or citation by tracing it through the original publication, methodology, source data, publication status, and independent replication."
---

# academic-verify — Trace Claims to Source Data

> Every verdict cites the source data, not just the author's claim about the
> source data.

## What this is

A claim-verification flow for academic / research statements. When a
book, article, or speaker cites a study or quotes a research result, this
Playbook traces the claim through:

```
claim → publication → methodology section → raw data source → independent verification
```

At each step, it answers:

- **Where does this result or number come from?** (Self-generated? Survey? Government data?)
- **What's the baseline?** (Reduction from what? Over what time period?)
- **Is the raw data available?** (Public? Proprietary? "Available on request"?)
- **What is the publication status?** (Current? Corrected? Expression of concern? Retracted?)
- **Has anyone independently verified it?** (Replication study? Government audit?)
- **Are there confounding factors?** (Other interventions, policy changes, COVID, sampling bias?)
- **Is the comparison fair?** (Cherry-picked comparison group? Survivorship bias?)

The verification records the claim, the trace, and the verdict so that a
reader can inspect how the evidence supports the conclusion.

## When to use this

- A book quotes a study and you want to confirm it is real and accurately
  cited
- An article makes a quantified claim ("X reduced Y by 40%") that you
  want traced to the source data
- You're writing something that depends on a piece of research and you
  want to verify the underlying paper holds up

## Academic verification method

```
Step 1: Scope the claim
  Pin down EXACTLY what's being claimed:
    • Quote: who said what?
    • Source: which paper / dataset / survey?
    • Result: what quantity, relationship, effect, or conclusion is claimed?
    • Scope: which population, comparison, baseline, and time period apply?

Step 2: Trace the evidence
  Find and inspect:
    • Original publication (title, authors, journal, year, DOI)
    • Methodology section summary
    • Raw data availability (public repo? proprietary?)
    • Publication status and post-publication review (Retraction Watch / PubPeer)
    • Independent replication or confirmation
    • Citations of the paper that critique or contextualize it

Step 3: Apply the verdict
  Apply one verdict using the Standards below:
    • Verified — claim is accurate; raw data is available or replication exists
    • Partially verified — claim correct on the underlying paper but
      methodology has known limits; record limits explicitly
    • Unverifiable — no public data, no replication; not enough to act
    • Misattributed — the claim cites a paper but the paper doesn't say that
    • Retracted / disputed — paper has known retraction or
      well-documented critique

Step 4: Link to original sources
  Cite the original paper and each inspected source directly.
```

## Output: report format

```markdown
# [Claim summary] — [Verdict]

> One-line: the verdict + the bottom-line reason.

## The Claim

> Exact quote, exactly as stated, with source attribution.

## Trace

| Step | Finding | Source |
|------|---------|--------|
| Original publication | [Title, authors, year, DOI] | [URL] |
| Methodology | [1-line summary; flag obvious limits] | [URL] |
| Raw data | [Public repo / proprietary / available-on-request] | [URL] |
| Publication status | [Current / corrected / expression of concern / retracted] | [URL] |
| Independent replication | [Replication studies and their results] | [URL] |
| Critical citations | [Papers that critique this work] | [URL] |

## Verdict

[Verified, Partially verified, Unverifiable, Misattributed, or Retracted / disputed]

[1-2 paragraphs explaining WHY the verdict, with specific evidence.]

## Caveats

[Honest limits: what we couldn't verify, what would change the verdict.]

## See Also

- Original paper: [Title](DOI URL)
- Related claims (verified or otherwise): [...]
```

## Useful databases

| Database | What it has | URL pattern |
|----------|-------------|-------------|
| Retraction Watch | Retractions, corrections, expressions of concern | retractionwatch.com/?s=NAME |
| PubPeer | Anonymous post-publication peer review | pubpeer.com/search?q=NAME |
| OSF | Pre-registrations, open data, open materials | osf.io/search/?q=QUERY |
| Semantic Scholar | Citation analysis, paper metadata | api.semanticscholar.org |
| OpenAlex | Open citation data, institutional affiliations | api.openalex.org |
| Many Labs | Replication results for social psychology | osf.io/wx7ck/ |
| Crossref API | DOI metadata, publication status | api.crossref.org/works?query=QUERY |
| Europe PMC | Biomedical literature, preprints, open access | ebi.ac.uk/europepmc/webservices/rest/search?query=QUERY |
| Harvard Dataverse | Raw research datasets, CSVs, survey microdata, replication packages | dataverse.harvard.edu/api/search?q=QUERY |
| ClinicalTrials.gov | Trial pre-registrations, outcome metrics | clinicaltrials.gov/api/v2/studies?query.term=QUERY |
| arXiv | Preprints (CS/Math/Physics), paper version histories (v1 vs v2) | export.arxiv.org/api/query?search_query=all:QUERY |
| FRED (St. Louis Fed) | Macroeconomic time-series (GDP, inflation, interest rates) | fred.stlouisfed.org/searchresults?st=QUERY |
| World Bank API | Global country-level development & macro indicators | api.worldbank.org/v2/country/all/indicator/?format=json |
| SEC EDGAR | Official US corporate financial filings (10-K, 10-Q) | sec.gov/edgar/search/#/q=QUERY |
| SIPRI | Global defense, military spending & arms transfer datasets | sipri.org/databases |


## Standards (the rigor bar)

- **Verified** — only when the underlying paper exists, raw data is
  public OR an independent lab has confirmed the result, and the citing
  source represents the claim accurately.
- **Partially verified** — paper is real and findings stand, but the citation
  context oversells (e.g., "X causes Y" when the paper shows correlation, or
  "all studies find X" when it's one underpowered study).
- **Unverifiable** — the underlying result or number can't be traced to source
  data, no replication has been done, no independent confirmation
  exists. Not the same as "wrong" — say "we couldn't verify."
- **Misattributed** — the citation points to a paper, but the paper
  doesn't actually say what the citation claims. Common in policy briefs.
- **Retracted / disputed** — paper has been retracted, has a major
  expression-of-concern, or has well-documented critique that
  contradicts the headline finding.

Never claim a problem without evidence. The verification document
itself is the artifact — if the claim holds up, say so plainly. If it
doesn't, the trace speaks for itself.

## Anti-Patterns

- ❌ Stating "Verified" without confirming raw data availability or
  independent replication. Replication trumps any single paper.
- ❌ Stating "Unverifiable" when you simply didn't look hard enough.
  The verdict is on the source, not on your search effort.
