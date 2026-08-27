---
name: brain-memory
description: Use when writing long-term memory with the remember tool, when a memory page type is rejected or a schema promotion needs a name, or when deciding what deserves to be remembered.
default_enabled: true
---

# Brain memory filing

The `remember` tool writes one durable memory unit into the shared knowledge
space. Follow these rules; the server enforces the mechanical ones.

## Filing rules

1. One call carries exactly one assertion that can change independently.
   Split compound statements into separate calls.
2. `holder` is who holds the judgment, not who it is about. "A says B is
   unreliable" is a take held by A, not a fact about B.
3. Relaying another person's judgment keeps their holder. Your own
   endorsement is a separate take with weight at most 0.55.
4. A fact self-reported by its subject caps confidence at 0.75. Only
   independent corroboration justifies more.
5. `weight` and `confidence` are multiples of 0.05.
6. Skip greetings, transient operational detail, and anything without
   long-term value. Prefer writing nothing over writing noise.
7. Choose the audience scope with the ConfidentialityPolicy guidance: the
   widest applicable scope that breaks no known confidentiality
   requirement. Split mixed-scope material into separate calls.
8. A background job can read memory but cannot write it. When a job you
   delegated returns, file the conclusions with long-term value yourself;
   nothing else keeps them.

## Vocabulary for schema evolution

`vocabulary.yml` in this skill folder is the shared naming reference of the
knowledge space. Consult it when a naming or schema question comes up: a
write path rejects a page type as not installed, a schema promotion needs a
name for a new type or subtype, or a recurring concept needs one canonical
term. Search it with `rg -i "<concept>" vocabulary.yml` and prefer its term
over an invented synonym. Installed schema types and subtypes always take
priority over the vocabulary.
