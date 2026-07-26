---
title: API documentation generator
description: How to set up an agent that generates API documentation from code — endpoint reference pages, request/response examples, and error catalogs — from the route definitions and types.
section: Guides
order: 364
---

An API documentation generator agent reads the codebase's route definitions, request/response types, and error handlers, and generates structured API documentation — endpoint reference pages with parameters, response shapes, status codes, and examples. This guide is the practical shape of that agent. It is a variant of the [code documentation agent](../code-documentation-agent/) focused on the API surface specifically.

The decisive property, stated up front: the agent **documents the API from the code, not from a spec**. It reads what the routes actually accept and return, and writes documentation that matches the implementation. If the implementation and the spec disagree, the agent documents the implementation (and flags the drift). The value is in keeping the API docs in sync with the code.

## What you need

- **Git credentials in WorkerEnv** (`GIT_TOKEN`). See [Git integration](../git-integration/).
- **`primary` and `coding` profiles bound** — reading route definitions and types requires code comprehension.
- **A signal binding** to the channel where documentation drafts post.
- **The repo accessible from the worker**, with route definitions the agent can discover.

## The workflow

1. **A documentation task arrives** — scheduled, or after an API change.
2. **The agent discovers the routes** — reads the router file(s) to find every endpoint: method, path, handler, middleware.
3. **The agent reads each handler** — for each route: parameters (path, query, body), response type, status codes, error cases.
4. **The agent reads the types** — the request body schema, the response body schema, the error envelope.
5. **The agent generates documentation** — one reference page per endpoint (or one page per resource group), with the method, path, parameters, response, errors, and a curl example.
6. **The agent posts the draft** — or opens a PR with the documentation changes.

## The endpoint reference

A good API reference page the agent generates:

```markdown
## POST /api/v1/payments

Create a payment charge.

**Request body**:
| Field | Type | Required | Description |
|---|---|---|---|
| amount | number | yes | The amount to charge, in cents |
| currency | string | yes | ISO 4217 currency code |
| customer_id | string | yes | The customer to charge |

**Responses**:
| Status | Body | Description |
|---|---|---|
| 200 | `Payment` | The created payment |
| 400 | `Error` | Invalid request body |
| 402 | `Error` | Payment declined by the provider |
| 500 | `Error` | Internal server error |

**Example**:
```bash
curl -X POST https://api.example.com/v1/payments \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"amount": 5000, "currency": "usd", "customer_id": "cus_123"}'
```
```

## What the persona controls

- **Discovery** — "read the Phoenix router (`lib/.../router.ex`) for Elixir, the Express routes for Node, or the framework's route declarations."
- **Depth** — "full reference with curl examples" vs "summary table with method, path, and one-line description."
- **Grouping** — "one page per resource group (payments, users, auth)" vs "one page per endpoint."
- **Drift detection** — "if the OpenAPI spec exists, compare the generated docs to it. Flag any mismatch."

## A worked example

Set up an API documentation generator for a Phoenix API:

1. Store `GIT_TOKEN` in WorkerEnv.
2. Create the agent, bind `primary`/`coding`.
3. Author `MISSION.md`: "Read the router in `lib/ankole_web/router.ex`. For each route under `/api/v1`, read the controller and the schema modules. Generate a Markdown reference page per resource group, with: method, path, parameters, response types, status codes, and a curl example. Post the draft for review. Do not modify the code."
4. In the channel: "Generate the API docs for the payments and auth endpoints."
5. The agent reads the router, reads the controllers and schemas, generates the reference pages, and posts the draft.

## What this guide is not

It is not an OpenAPI spec generator — it generates human-readable documentation, not a machine-readable spec (though it can read an existing spec for drift detection). For spec validation, read [API contract validator](../api-contract-validator/). It is not a code documentation agent — it documents the API surface, not the internal code. And it is not a substitute for a human technical writer — the generated docs are a draft; the writer adds context, use cases, and the narrative.

## Next steps

- For the code documentation pattern (internal docs, not API), read [Code documentation agent](../code-documentation-agent/).
- For the contract validator (spec vs implementation drift), read [API contract validator](../api-contract-validator/).
- For git setup, read [Git integration](../git-integration/).
- For the shell tools, read [Code execution](../code-execution/).
