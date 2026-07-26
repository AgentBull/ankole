---
title: Deployment assistant
description: How to set up an agent that assists with deployments — runs pre-deploy checks, applies the deploy, verifies health, and rolls back if the smoke test fails.
section: Guides
order: 353
---

A deployment assistant agent runs the pre-deploy checklist, applies the deployment, verifies the service is healthy, and rolls back if the smoke test fails. This guide is the practical shape of that agent. It is closely related to the [updating](../updating/) guide (which covers the operator's manual deploy procedure) — this page covers an agent that assists with or automates that procedure.

The decisive property, stated up front: the agent **deploys and verifies, but rolls back on failure**. It applies the change, checks health, and if the smoke test fails, reverts to the previous known-good state. The value is in the verification loop — catch a bad deploy before users do — not in the speed of deployment.

## What you need

- **Git credentials in WorkerEnv** (`GIT_TOKEN`) — if the deployment involves pulling code.
- **`primary` profile bound** — the agent reads health-check output and decides pass/fail.
- **A signal binding** to the channel where deploy status posts.
- **Deployment access** — the agent needs shell access to the deployment commands (`docker compose`, `helm`, `kubectl`, or your CI's deploy trigger).
- **A smoke test** — a request the agent sends after deploy to verify the service works.

## The workflow

1. **A deploy request arrives** — "deploy branch `release-v2` to staging," or a webhook from CI.
2. **The agent runs pre-checks** — confirm the branch builds, the tests pass, the image is available.
3. **The agent applies the deploy** — `docker compose pull && docker compose up -d --force-recreate`, or `helm upgrade`, or the CI trigger.
4. **The agent waits for health** — polls the health endpoint until it returns healthy, with a timeout.
5. **The agent runs the smoke test** — sends a request to a known endpoint and checks the response.
6. **Pass → report success. Fail → roll back** — if the smoke test fails, the agent reverts to the previous image/tag and reports the failure with the smoke-test evidence.

## What the persona controls

- **Pre-checks** — "confirm `bun test` passes, the Docker image exists in the registry, and the database backup was taken."
- **The deploy command** — the exact command for your deployment target.
- **The health check** — "poll `GET /health` every 5 seconds for 60 seconds. Healthy = 200 OK."
- **The smoke test** — "send `GET /api/v1/status` and check for `{"status":"ok"}`."
- **The rollback** — "if the smoke test fails, run `docker compose down && docker compose up -d` with the previous image tag. Report the failure."
- **What not to do** — "do not deploy to production without explicit human approval. Do not skip the database backup."

## The rollback discipline

The rollback is the safety net. The persona must enforce:

- **Rollback is automatic on smoke-test failure** — the agent does not wait for a human to decide; it reverts immediately and reports.
- **Rollback is to the previous known-good state** — the previous image tag, not a guess. The agent records the current tag before deploying so it can revert.
- **A database migration is not reversible** — the agent can roll back the image, but if the deploy included a migration, the agent reports "image rolled back, but migration X was applied and is not reversible. Manual intervention needed."

## A worked example

Set up a deployment assistant for a Docker Compose deployment:

1. Create the agent, bind `primary`/`coding`.
2. Author `MISSION.md`: "On deploy request: run `bun test`. If pass: record current image tag, `docker compose pull && docker compose up -d --force-recreate`. Poll `/health` for 60s. Send smoke test to `/api/v1/status`. If smoke test fails: revert to previous tag, `docker compose up -d`. Report result. Do not skip the backup."
3. In the channel: "Deploy release-v2 to staging."
4. The agent tests, records, deploys, health-checks, smoke-tests, and reports (or rolls back).

## What this guide is not

It is not a CI/CD pipeline — the agent assists with a specific deploy, triggered by a human or a webhook; it does not replace your pipeline. It is not a blue-green deploy tool — the agent does sequential deploy-and-verify, not parallel-environment switching. And it is not a substitute for the [updating](../updating/) guide — that page covers the operator's manual procedure; this page covers the agent that assists.

## Next steps

- For the manual deploy procedure, read [Updating](../updating/).
- For the rollback mechanics (image + migration), read [Updating](../updating/) and [Backup and restore](../backup-and-restore/).
- For the shell tools (deploy commands), read [Code execution](../code-execution/).
- For incident response (what happens after a failed deploy), read [Incident response](../incident-response/).
