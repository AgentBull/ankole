---
name: port-deep-research-playbook
description: Port an external Skill, paper, or methodology into an Ankole Deep Research Playbook. Use when adding or revising a Playbook under app/library/agent-plugins/deep-research/workspace-template/playbooks from an external research source.
---

# Port External Research into a Deep Research Playbook

A port preserves the source's research semantics across an ownership boundary.
The source supplies the method. Ankole supplies the research lifecycle. The
Playbook contains only the rules that its type of research deliverable adds.

## 1. Lock the source

Resolve the canonical source before you design the Playbook. Record its URL or
path, revision or publication version, content hash, author, and applicable
license or attribution terms. Prefer a raw, versioned file over a rendered
repository page.

For a new port from an external Skill whose reuse terms permit adaptation:

1. Save an immutable temporary snapshot of the exact source bytes.
2. Create the target Playbook as a byte-for-byte copy of that snapshot.
3. Prove the baseline with `cmp` and matching hashes.
4. Begin adaptation after both checks pass.

For a paper, prose methodology, or source with narrower reuse terms, keep the
exact publication as the temporary immutable source. Extract its method,
definitions, evidence requirements, limitations, and source catalog. Use
paraphrase and citation according to its reuse terms.

For an update to an existing port, resolve the previously recorded revision,
compare it with the new source, and separate upstream changes from Ankole
adaptations before editing.

Pause when the canonical source, revision, or reuse terms remain unresolved.
Resume with those facts recorded.

**Completion criterion:** The exact source identity is reproducible, its
provenance is recorded, and an external Skill has a proven byte-for-byte target
baseline before the first adaptation.

## 2. Build the port ledger

Read the current target owners before assigning source content:

- `docs/design-docs/Plugins.md` defines Plugin and workspace ownership.
- `app/library/agent-plugins/deep-research/workspace-template/AGENTS.md` owns
  the research lifecycle, source collection, capability selection, default
  verifier, deliverable path, and working state.
- `app/library/agent-plugins/deep-research/workspace-template/playbooks/` owns
  routing, domain methods, domain source catalogs, domain-specific report
  content, and a special verifier protocol only when the method requires one.
- `app/library/agent-plugins/deep-research/workspace-template/tools/` owns
  deterministic checks for machine-checkable artifacts introduced by a
  Playbook.
- `app/library/agent-plugins/deep-research/THIRD-PARTY-NOTICES.txt` owns copied
  source provenance and required license text.

Inspect relevant existing Playbooks, `tools/list_playbooks.ts`, the discovery
test, the root changelog, and the current dirty-tree diff. Re-read every target
file immediately before editing it.

Keep a temporary ledger with one row for every source section:

| Source unit | Semantic purpose | Target owner | Decision | Reason |
|-------------|------------------|--------------|----------|--------|
| Section or metadata field | Behavior it supplies | Existing owner | Retain, adapt, relocate, or omit | Concrete ownership or impedance fact |

Retention is the default. Retain research questions, methods, source catalogs,
standards, examples, caveats, and anti-patterns. A recorded target fact earns a
change. Its section-level reason must name the conflicting owner, external
dependency, output model, metadata contract, or source defect.

**Completion criterion:** Every source section and metadata field has exactly
one ledger decision, and every adaptation, relocation, or omission names a
current target fact.

## 3. Define the route positively

Match the current Playbook frontmatter contract. Write the description as a
positive identity for the requested deliverable:

```yaml
description: "Use when the requested research deliverable ..."
```

Name the subject, operation, evidence chain, and result that make this method
applicable. Use those positive properties to keep recall narrow. Keep examples
inside the same declared class.

**Completion criterion:** The description identifies one research-deliverable
class from its positive properties, and every use example belongs to that
class.

## 4. Port by ownership

Apply the ledger from top to bottom. Preserve source wording when it remains
correct in Ankole. Adapt a concept at its owner boundary:

- Convert Skill metadata into the current Playbook metadata contract.
- Keep domain questions, methods, databases, standards, caveats, and useful
  examples in the Playbook.
- When `AGENTS.md` already owns execution, collection, capability choice,
  verification, or the deliverable path, leave that behavior with
  `AGENTS.md`. State only the method-specific evidence requirement in the
  Playbook.
- Convert an external output model into domain-specific report content while
  the workspace keeps ownership of the report artifact and its path.
- Inline a source convention only when the Playbook needs its domain rule to
  remain self-contained. Let the existing global owner keep shared lifecycle
  rules.
- Keep provenance distinct from runtime dependency. A source citation or
  notice records origin. Runtime dependencies supply capabilities required at
  execution time.
- Use the existing Playbook, workspace `AGENTS.md`, `tools/`, and Plugin notice
  owners. A new directory requires a distinct durable owner in the design.

Treat a source-internal defect as its own ledger item. Repair it during the
port when it would make the adapted contract contradictory or unusable, and
record the reason. Preserve other source semantics for a separate change.

**Completion criterion:** Every final difference from the locked source maps
to one ledger row, all retained sections remain represented, and each
workspace behavior remains single-owned by `AGENTS.md`.

## 5. Run the full-artifact semantic audit

Treat each user-reported defect as evidence of a defect class. Re-audit the
complete source-to-target mapping for that class before editing the example.

Derive the audit from these questions:

1. What user-visible research result must this Playbook improve?
2. Which rules are unique to that result?
3. Which current Ankole owner already supplies every other rule?
4. Does each retained source section still mean the same thing?
5. Does an adapted heading or parenthetical accidentally constrain a general
   capability or source catalog?
6. Does the text separate related concepts such as discovery and access,
   publication status and replication, or attribution and truth?
7. Do routing, examples, steps, verdict labels, standards, and report
   placeholders describe the same domain?
8. Does each template work for every value that the method permits?
9. What defect in the same class remains outside the user's example?

Compare the final Playbook with the locked source line by line. Classify every
changed or deleted block through the ledger. Resolve each unexplained diff by
correcting it or adding an evidence-based ledger reason.

**Completion criterion:** Every audit question has an evidence-based answer,
every source-to-target diff is classified, and all defects found in the same
class as a reported example are resolved together.

## 6. Integrate the Playbook

Keep the Playbook self-contained. Update the discovery expectation when the
new file changes the listed Playbooks. Cite papers and prose methodologies in
the Playbook. Add or update Plugin-root attribution when retained copied
material or its reuse terms require a notice, including the canonical source,
revision, hash, license, and a precise modification summary. Follow the current
dirty changelog rule and describe every retained file in the pending version.

Create a deterministic tool only when the method introduces a structured
artifact with mechanically checkable invariants. Keep semantic research
quality in the Playbook and human-readable audit.

**Completion criterion:** Discovery, attribution, tests, and changelog all
describe the same Playbook and source revision, and every retained convention,
reference, or tool has a current owner and caller.

## 7. Prove the port

Run the current repository checks, including:

```bash
bun app/library/agent-plugins/deep-research/workspace-template/tools/list_playbooks.ts
bun test app/agent_computer/test/playbook-discovery.test.ts
bun run --cwd app/agent_computer lint
git diff --check
```

Also prove these semantic properties directly:

- compare retained source sections against the locked snapshot;
- scan for every external concept and dependency named in the ledger;
- confirm the Playbook contains domain method and report content while
  workspace lifecycle and capability routing remain in `AGENTS.md`;
- inspect the complete diff, notice, and changelog together; and
- state any validation that the current environment could not run.

Tests prove structure. The port ledger and semantic audit prove fidelity and
ownership.

**Completion criterion:** Structural checks pass, source preservation and
impedance removal have direct evidence, every retained diff belongs to the
declared change, and the handoff reports the source revision, preserved core,
adaptations, validation, and remaining uncertainty.
