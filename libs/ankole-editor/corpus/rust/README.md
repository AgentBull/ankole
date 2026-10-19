# Rust document corpus

`index.json` is the single golden file. Format version 2 has these sections:

- `xml`: source XML, canonical XML, and the actual Wordgard document JSON.
- `invalid`: rejected XML and the parser error.
- `boundaries`: compact source fragments. Repeat each `text` by its `count`,
  then join the fragments. `error: null` means acceptance. Each source, node,
  and depth limit has an accepted boundary and a source one unit above it.
- `edits`: initial XML and document, ordered `ChangeSet.toJSON()` batches,
  and the expected client XML and document after every batch.

Document JSON is Wordgard's internal format. A Rust reader must map it to its
own document model. ChangeSet JSON is an array; it is not a transaction spec
or an object with a `sections` field. Positions use UTF-16 code units.

Each edit batch can contain several local operations. It composes the production
transactions and their appenders, then uses `preparePageUpdate` on its final
transaction. The client applies that prepared transaction, and its serialized
changes include the correction. Intermediate operations need not be canonical.
The chains cover text insertion, deletion, replacement, marks, block changes,
tables, unknown nodes, embeds, Unicode, line breaks, and invalid input characters
removed at submission. Generated chains use the stored
seed. The property test shrinks a failing page and operation sequence and
reports the seed and replay path.

Run `bun run generate:corpus` to update the golden file. `FC_SEED` can select
a generation seed. Run `bun run test:corpus` to check the saved file without
rewriting it. `FC_SEED` selects the independent property-test seed; the golden
file check always uses the seed stored in the file.

The replay check compares the in-memory client with a server that reads and
writes XML after every batch. It also compares the document read back from
each stored step. A mismatch is a failed preflight, not proof that a Rust
implementation is compatible. Rust apply and concurrent OT transform are
outside this corpus generator.
