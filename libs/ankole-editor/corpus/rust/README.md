# Rust document corpus

`index.json` is the shared golden corpus (format version 2), organized into four
sections:

- `xml`: input XML, canonical XML, and the corresponding Wordgard document JSON.
- `invalid`: rejected XML inputs paired with their expected parser errors.
- `boundaries`: compact source fragments expanded by repeating each `text` entry
  `count` times and joining the pieces. `error: null` indicates an accepted
  input; every source-length, node-count, and nesting-depth limit is tested both
  at the maximum allowed bound and one unit past it.
- `edits`: an initial XML string and document, an ordered list of
  `ChangeSet.toJSON()` batches, and the expected client XML and document after
  each batch.

Document JSON uses Wordgard's internal serialization format, so a Rust consumer
must map it onto its own document model. `ChangeSet` JSON is a flat array—not a
transaction spec or an object with a `sections` field—and all character offsets
count UTF-16 code units.

Each edit batch may combine multiple local operations: the generator composes
production transactions and their appenders, then runs `preparePageUpdate` on
the final transaction of the batch. Because the client applies that prepared
transaction, the serialized change set already folds in normalization
corrections, while intermediate operations within a batch need not be canonical.
Edit chains exercise text insertion, deletion, and replacement, inline marks,
block conversions, tables, unknown elements, embeds, Unicode scalar boundaries,
line breaks, and invalid input characters stripped on submission. Generated
chains are deterministic from the seed recorded in `index.json`; when a
property-test run fails, `fast-check` shrinks both the initial page and the
operation sequence and prints the failing seed and replay path.

To regenerate `index.json`, run `bun run generate:corpus` (set `FC_SEED` to
choose a different generation seed). To verify the committed golden file without
rewriting it, run `bun run test:corpus`: the golden check always replays the
seed stored inside `index.json`, whereas `FC_SEED` overrides the seed for the
separate property-test run.

During replay, `test:corpus` compares the in-memory client state against a
simulated server that parses and reprints XML after every batch, and checks the
document re-imported at each step. A mismatch fails preflight for the corpus
itself; Rust change-set application and concurrent OT transformation are tested
outside this generator (`bun run --filter @ankole/block-editor test:rust`).
