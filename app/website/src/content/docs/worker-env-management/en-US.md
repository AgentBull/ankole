---
title: WorkerEnv management
description: The operator's task-oriented view of WorkerEnv — add, list, attach, detach, rotate, and decrypt shell environment variables for workers.
section: User guide
order: 60
---

WorkerEnv is the encrypted shell-environment store that workers read when a turn starts. This page is the operator's task-oriented view of managing it — the routes, the scopes, the rotation discipline, and the decrypt permission. It complements the [WorkerEnv secrets](../worker-env/) concept page with concrete operations.

The decisive property, stated up front: changes take effect on the **next turn**, not on one already running. A secret you save reaches the worker on its next turn; a turn in flight keeps the environment it started with.

## List and read

```bash
curl https://ankole.example.com/api/v1/worker-envs \
  -H "Authorization: Bearer $CONSOLE_TOKEN"

curl https://ankole.example.com/api/v1/worker-envs/MY_API_KEY \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /worker-envs` lists global entries. `GET /worker-envs/:name` reads one. Listing and reading return metadata, not the secret value — the `secret` flag tells you whether the value is encrypted.

## Add or update a global variable

```bash
curl -X PUT https://ankole.example.com/api/v1/worker-envs/MY_API_KEY \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "value": "sk-...", "secret": true }'
```

`PUT /worker-envs/:name` creates or updates a global variable. The `secret` flag controls whether the value is encrypted at rest — set it for anything sensitive.

## Attach a variable to one agent

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/worker-envs/MY_API_KEY \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "value": "sk-...", "secret": true }'
```

Per-agent variables override global ones for that agent. List an agent's effective variables with `GET /agents/:agent_uid/worker-envs` — the response includes provenance (which track each variable came from).

## Detach a variable from an agent

```bash
curl -X DELETE https://ankole.example.com/api/v1/agents/<agent_uid>/worker-envs/MY_API_KEY \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

Detaching removes the per-agent override; the global value (if any) takes effect again on the next turn.

## Rotate a secret

Rotation is the safe alternative to decryption. Set a new value through `PUT`; the old value is overwritten. The new value reaches the worker on its next turn. Do not decrypt the old value to "check" — set the new one and move on.

## Decrypt (use sparingly)

```bash
curl -X POST https://ankole.example.com/api/v1/worker-envs/MY_API_KEY/decryptions \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`POST .../decryptions` reveals the stored value. It is a separately authorized action — the `decrypt` permission, distinct from `read`. Use it only when you genuinely need to see the stored value (debugging, confirming before a scripted rotation). Each decryption is observable.

## The merge order

An agent's effective environment is a merge, from lowest to highest precedence:

1. declared variables (AppConfigure with `worker_env_name`)
2. global custom variables
3. per-agent custom variables
4. binding-derived variables (from active adapters)
5. the model's explicit per-command `env`

Provider-derived identity wins over operator rows; the trusted model has the last word for a single command.

## Reserved names

Some names cannot be set through WorkerEnv: `PATH`, `HOME`, `SHELL`, `TERM`, `LANG`, `BASH_ENV`, `ENV`, `WORKER_ID`, `RUNTIME_FABRIC_URL`, `DATABASE_URL`, `CODEX_UNSAFE_ALLOW_NO_SANDBOX`, and anything starting with `ANKOLE_`. The store rejects them — these names are owned by the sandbox or the worker identity.

## What this guide is not

It is not the WorkerEnv concept page — for the three-track merge model, the encryption details, and the distinction from AppConfigure, read [WorkerEnv secrets](../worker-env/). It is not an AppConfigure guide — for operator-managed settings that are not shell variables, read [AppConfigure](../app-configuration/). And it is not a security-hardening guide — for the rotation and decrypt discipline, read [Security hardening](../security-hardening/).

## Next steps

- For the concept page, read [WorkerEnv secrets](../worker-env/).
- For AppConfigure (a different store), read [AppConfigure](../app-configuration/).
- For the security posture, read [Security hardening](../security-hardening/).
- For the Console routes, read the [Console API reference](../console-api/).
