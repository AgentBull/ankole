---
title: API testing agent
description: How to set up an agent that tests API endpoints — sends requests, checks responses, reports failures with evidence, and covers edge cases a static test suite misses.
section: Guides
order: 347
---

An API testing agent sends requests to an API, checks the responses against expectations, and reports failures with enough evidence to debug. It goes beyond a static test suite by adapting — trying edge cases, varying parameters, and exploring the API's behavior boundaries. This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **tests, it does not fix**. It sends requests, validates responses, and reports. A human decides whether a failure is a bug, a documentation gap, or expected behavior. The agent's value is coverage and adaptivity, not diagnostic authority.

## What you need

- **`primary` and `coding` profiles bound** — writing and adapting test requests requires reasoning about API contracts.
- **A signal binding** to the channel where test reports post.
- **The API accessible from the worker** — either a local dev server the agent starts, a staging URL, or an internal endpoint.
- **API credentials (if needed)** — store as WorkerEnv secrets.

## The workflow

1. **A testing task arrives** — "test the `/payments` endpoints," "verify the auth flow after the refactor," or a scheduled smoke test.
2. **The agent reads the API contract** — from an OpenAPI spec, existing tests, or the codebase's route definitions.
3. **The agent sends requests** — through `command` with `curl`, or through a script the agent writes. It covers the happy path, error cases, and edge cases (empty input, invalid types, boundary values).
4. **The agent validates responses** — status codes, response shape, field types, business-logic correctness.
5. **The agent reports** — a structured report: what passed, what failed (with the request, the response, and the expected behavior), and what was ambiguous.

## What makes it an agent, not a test runner

A test runner executes a fixed set of assertions. An agent adapts:

- **Edge-case exploration** — after the happy path passes, the agent tries variations the test suite does not cover: "what if the amount is negative? What if the currency is lowercase? What if the auth token is expired?"
- **Contract verification** — the agent reads the API spec and checks whether the actual response matches the documented contract, not just whether the status code is 200.
- **Failure investigation** — when a test fails, the agent reads the error response, identifies the likely cause, and includes that in the report.

## A worked example

Set up an agent that smoke-tests a REST API nightly:

1. Bind `primary`/`coding` + store the staging API key in WorkerEnv (`STAGING_API_KEY`).
2. Author `MISSION.md`: "Every night, smoke-test the staging API. Read the OpenAPI spec. Test each endpoint's happy path. Check status codes and response shapes against the spec. Try 2-3 edge cases per endpoint. Report: passed, failed (with request + response + expected), ambiguous. Do not fix."
3. Add a nightly schedule: `cron: "0 3 * * *"`.
4. The agent reads the spec, sends `curl` requests through `command`, validates responses, tries edge cases, and posts the report.

## Delegate large test suites

For an API with many endpoints, delegate the test run to a background job (see [Delegation patterns](../delegate-patterns/)). The job runs the full suite; the agent synthesizes the report when the job completes.

## What this guide is not

It is not a load-testing tool — the agent sends sequential requests, not concurrent load. For load testing, use a dedicated tool (k6, Locust, wrk). It is not a security scanner — the agent tests functional correctness, not vulnerabilities. And it is not a CI gate — the agent reports; the team decides what to block on.

## Next steps

- For the shell tools (`curl` through `command`), read [Code execution](../code-execution/).
- For the coding profile, read [Providers and models](../providers-and-models/).
- For scheduling, read [Cron schedules](../cron-schedules-ops/).
- For delegation, read [Delegation patterns](../delegate-patterns/).
