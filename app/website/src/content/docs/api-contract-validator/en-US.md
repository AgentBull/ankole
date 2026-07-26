---
title: API contract validator
description: How to set up an agent that validates an API implementation against its OpenAPI spec — checks shapes, types, status codes, and reports drift.
section: Guides
order: 356
---

An API contract validator agent reads an OpenAPI specification, sends requests to the actual API, and checks whether the implementation matches the documented contract — response shapes, field types, status codes, and error formats. This is a specialized form of the [API testing agent](../api-testing-agent/), focused on contract drift rather than functional correctness. This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **validates the contract, not the behavior**. It checks whether the API's response matches what the spec promises — not whether the behavior is correct. A response can be contract-valid but behaviorally wrong (the spec says "returns user object" and it does, but the user object has the wrong data). The agent catches the shape drift; the human catches the semantic bug.

## What you need

- **`primary` and `coding` profiles bound** — reading OpenAPI specs and comparing them to responses requires structured reasoning.
- **A signal binding** to the channel where validation reports post.
- **The API accessible from the worker** — a staging URL or a local server.
- **The OpenAPI spec** — a file in the repo, fetched through `web_fetch`, or served at `/openapi.json`.

## The workflow

1. **A validation task arrives** — scheduled, or after a spec change.
2. **The agent reads the OpenAPI spec** — parses the paths, methods, request schemas, response schemas, and status codes.
3. **The agent sends requests** — for each path+method in the spec, sends a request (with valid auth and a representative body).
4. **The agent compares** — checks the actual response against the spec: status code matches, response body has the documented fields with the documented types, error responses match the documented error schema.
5. **The agent reports drift** — any mismatch between spec and implementation.

## The drift report

```text
**Contract validation — <date>**
**Endpoints checked**: 42
**Pass**: 38
**Drift** (spec says X, implementation does Y):
- `GET /users/:id`: spec says `200` returns `{id, name, email}`; implementation returns `{id, name, email, created_at}`. Extra field.
- `POST /orders`: spec says `400` returns `{error: {code, message}}`; implementation returns `{error: string}`. Shape mismatch.
- `DELETE /sessions/:id`: spec says `204`; implementation returns `200`. Status mismatch.
```

The three drift types — extra fields, shape mismatches, and status mismatches — are the most common contract drift patterns. The agent reports each with the endpoint, the spec's claim, and the implementation's actual behavior.

## What the persona controls

- **Scope** — "validate all paths in the spec" vs "validate only the paths modified since the last spec commit."
- **Strictness** — "flag extra fields as drift" vs "allow extra fields (forward-compatible additions)."
- **Auth** — "use the staging API key from WorkerEnv for authenticated endpoints."
- **Reporting** — "report each drift as a separate finding with the spec reference and the actual response."

## A worked example

Set up a contract validator for a REST API:

1. Bind `primary`/`coding` + store the staging API key in WorkerEnv.
2. Author `MISSION.md`: "Read the OpenAPI spec from `openapi.json`. For each path+method, send a request to the staging API. Compare the response to the spec: status code, response body shape, field types. Report drift: extra fields, missing fields, type mismatches, status mismatches. Allow extra fields only if they are in a `metadata` object. Post the report."
3. Add a schedule that runs after each deploy: `cron: "0 * * * *"` (hourly), or trigger from a webhook.
4. The agent reads the spec, sends requests, compares, and posts the drift report.

## What this guide is not

It is not a functional test — it checks the shape, not the correctness of the data. It is not a spec generator — it validates against an existing spec; it does not write one (for that, see the [code documentation agent](../code-documentation-agent/)). And it is not a breaking-change detector across versions — it checks the current implementation against the current spec; comparing two spec versions is a different task.

## Next steps

- For the API testing pattern (functional, not contract), read [API testing agent](../api-testing-agent/).
- For the code documentation pattern (generating docs from code), read [Code documentation agent](../code-documentation-agent/).
- For the shell tools (sending requests), read [Code execution](../code-execution/).
- For scheduling, read [Cron schedules](../cron-schedules-ops/).
