---
title: WorkerEnv secrets
description: The encrypted shell-environment store for Agent Computer workers — three tracks, one merged environment per agent, decrypted only on the ephemeral RPC path to a turn.
section: Operations
order: 17
---

WorkerEnv is the store for the environment variables an Agent Computer shell sees when it runs a turn. An operator puts an API key or token here once, attaches it at the right scope, and the worker receives it — decrypted — only when a turn starts. This page maps the model against the real code in `Ankole.SignalsGateway.ActorRuntime.WorkerEnv`.

The decisive property, stated up front: secret values are encrypted at rest with a key derived per row, and the only place the decrypted flat map exists is the ephemeral RPC path to the worker. Nothing durable stores the merged environment. Browsing configuration never reveals a secret; revealing one is a separate, separately-authorized action.

## Three tracks, one merged environment

The shell environment a worker sees is a merge of three tracks, and understanding the merge is the whole game:

- **Declared variables** are AppConfigure definitions marked with a `worker_env_name`. Their schema, encryption, description, and per-agent overrides stay with AppConfigure; WorkerEnv only projects the resolved value into the shell. Marked definitions must register at boot, not lazily, or enumeration misses them.
- **Custom variables** are free-form operator rows in `agent_computer_worker_envs`, either global or per agent, each with a per-row `secret` flag. This is the table the Console reads and writes.
- **Binding-derived variables** are resolved by the agent's active signal adapters. They are ephemeral — they never become editable Console rows.

The merge order, low to high, is: declared, then custom global, then custom agent, then binding-derived, then the model's explicit per-command `env`. Provider-derived identity wins over operator rows, while the trusted model still has the last word for a single command. A binding-derived token for the provider the agent is actually connected to will override an operator row of the same name — which is usually what you want.

## Names and reserved names

A WorkerEnv name is a shell variable name: it must match `~r/\A[A-Za-z_][A-Za-z0-9_]*\z/`. Some names are reserved because the sandbox bootstrap or the worker identity owns them — `PATH`, `HOME`, `SHELL`, `TERM`, `LANG`, `BASH_ENV`, `ENV`, `WORKER_ID`, `RUNTIME_FABRIC_URL`, `DATABASE_URL`, `CODEX_UNSAFE_ALLOW_NO_SANDBOX`, and anything starting with `ANKOLE_`. Overriding these from operator rows would not restrict the model — it can re-export inside the shell — but it would break the sandbox contract in confusing ways, so the store rejects them.

## Encryption: one key per row

Secrets are sealed with kernel-backed AEAD encryption. The row key is derived from both the scope and the name, so a ciphertext copied to another row cannot decrypt as a valid value. The key-derivation domain is `worker_env`, which keeps these ciphertexts unreadable as AppConfigure rows and vice versa — the two stores cannot read each other's secrets even though both use the same kernel primitive.

Values are plain strings by contract, because shell variables are strings; no JSON round-trip happens in the crypto layer. A declared key that resolves to a non-string, non-nil value is treated as a declaration bug and fails loudly, rather than exporting garbage into shells.

## Per-name routing: one editing surface

Console reads and writes route by name, so the operator sees one editing surface even though the backing tracks differ. A name resolves to its custom row first (matching merge precedence), then to its declared definition, and otherwise creates a custom row. This is why the operator never has to know which track a variable lives on to change it.

## The routes

The Console surface splits into global and per-agent scopes, each with read, write, delete, and decrypt:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/worker-envs` | List global variables |
| `GET` | `/worker-envs/:name` | Read one global variable (metadata, not plaintext) |
| `PUT` | `/worker-envs/:name` | Create or update a global variable |
| `DELETE` | `/worker-envs/:name` | Remove a global variable |
| `POST` | `/worker-envs/:name/decryptions` | Decrypt one global variable |
| `GET` | `/agents/:agent_uid/worker-envs` | List one agent's effective variables with provenance |
| `PUT` | `/agents/:agent_uid/worker-envs/:name` | Create or update a per-agent variable |
| `DELETE` | `/agents/:agent_uid/worker-envs/:name` | Remove a per-agent variable |
| `POST` | `/agents/:agent_uid/worker-envs/:name/decryptions` | Decrypt one per-agent variable |

Listing and reading return metadata, not the secret value. Each action runs under the Console policy — read, update, reset, and decrypt are distinct actions on `worker_env:<name>` and `agent:<uid>:worker_env:<name>` resources.

## Decryption is a separate permission

Revealing an encrypted value is its own authorized action, distinct from reading the row. The policy action is `worker_env:<name>` `decrypt`, separate from `read` and `update`. This is deliberate: an operator who can browse configuration cannot, by that fact alone, see secret material. Decrypting a value is an observable, privileged act, not a side effect of reading the list.

## The turn-injection boundary

When a worker starts a turn, it calls the `worker_env.resolve` RuntimeFabric RPC. The broker resolves the agent to an active principal, computes the merged environment with secrets already decrypted, and returns it on the ephemeral RPC path. The decrypted flat map never touches durable storage — it exists only for the trip from the control plane to the worker for that turn.

Two consequences follow. First, Agent Computer is a trusted first-party runtime node; it receives decrypted secrets because it is trusted, and it does not get to resolve another agent's environment. Second, a change to a WorkerEnv value takes effect on the next turn, not on a turn already running — the running turn already has its environment. This is the same "next turn, not this turn" property the [Background Agent Jobs](../background-agent-jobs/) page describes for worker-secret changes.

## How it differs from AppConfigure and Control Plane Plugins

Ankole has three configuration surfaces that touch process or shell behavior, and WorkerEnv is the one that specifically holds shell variables for worker turns:

- **AppConfigure** holds operator-managed application settings — including the declared WorkerEnv definitions themselves. When a declared variable is marked with `worker_env_name`, AppConfigure owns its schema, encryption, description, and per-agent overrides; WorkerEnv only projects the resolved value. A custom row in `agent_computer_worker_envs` is the operator's free-form escape hatch when there is no declared definition.
- **Control Plane Plugins** contribute AppConfigure keys and supervised children at boot. A plugin can declare a `worker_env_name` AppConfigure key; once it does, that variable flows through WorkerEnv like any declared variable. The plugin is the source of the declaration; WorkerEnv is the projection into the shell.
- **WorkerEnv** is the merged, name-routed, decrypt-on-RPC shell environment. It is not where configuration lives; it is where shell variables reach the worker.

The split keeps each surface honest about what it owns: AppConfigure owns settings, plugins own declarations, WorkerEnv owns the shell projection and the secret-handling discipline.

## What WorkerEnv is not

It is not a general secret store. It holds shell variables for worker turns, encrypted at rest with per-row keys, and nothing else. It is not a way to give the model credentials the operator did not approve — binding-derived variables come from active adapters the operator bound, and reserved names are off limits. And it is not durable in its merged form; the flat decrypted map exists for one RPC hop. The durable facts are the rows; the merged environment is rebuilt every turn.

## Next steps

- For the worker that receives this environment, read the [Agent Computer](../agent-computer/) page.
- For the AppConfigure definitions a declared variable comes from, read the [Console](../console/) page.
- For the "next turn, not this turn" property shared with secret changes, read [Background Agent Jobs](../background-agent-jobs/).
