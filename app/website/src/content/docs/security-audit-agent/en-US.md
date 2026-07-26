---
title: Security audit agent
description: How to set up an agent that scans a codebase for security issues — dependency vulnerabilities, injection risks, hardcoded secrets — and reports with severity and remediation.
section: Guides
order: 349
---

A security audit agent reads a codebase, scans for common security issues — known-vulnerable dependencies, injection risks, hardcoded secrets, misconfigured auth — and reports each finding with severity and a remediation suggestion. This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **audits, it does not patch**. It identifies issues and reports them. A human decides whether to fix, defer, or accept the risk. The agent's value is coverage and consistency, not the authority to change security-critical code.

## What you need

- **Git credentials in WorkerEnv** (`GIT_TOKEN`). See [Git integration](../git-integration/).
- **`primary` and `coding` profiles bound** — security analysis requires code comprehension.
- **A signal binding** to the channel where audit reports post.
- **The repo accessible from the worker.**

## The workflow

1. **An audit task arrives** — a scheduled scan, a pre-release check, or a human request.
2. **The agent clones and scans** — runs dependency checks (`npm audit`, `bun audit`, `pip-audit`, or similar), reads the code for injection patterns, checks for hardcoded secrets, inspects auth configuration.
3. **The agent classifies** — severity (critical/high/medium/low), category (dependency, injection, secret, config), and exploitability.
4. **The agent suggests remediation** — for each finding: what to do (upgrade, patch, remove, configure), with the specific version or config change.
5. **The agent reports** — a structured report: findings by severity, with the file, the issue, the evidence, and the remediation suggestion.

## What the persona controls

- **Scope** — "scan dependencies, source code, and configuration files. Do not scan test fixtures or generated code."
- **Severity thresholds** — "report critical and high findings immediately; batch medium and low into a weekly summary."
- **Remediation depth** — "suggest the specific version to upgrade to, with the CVE link. For code issues, suggest the fix pattern but do not write the patch."
- **Secret detection** — "check for hardcoded API keys, passwords, and tokens using pattern matching. Flag anything that looks like a credential."

## The known-vulnerability check

The most valuable automated check is the dependency scan. The agent runs the language ecosystem's audit tool:

```bash
bun audit    # Bun/Node
pip-audit    # Python
cargo audit  # Rust
mix deps.audit # Elixir (if the tool is available)
```

For each vulnerability found, the agent reports: the package, the CVE, the severity, and the fixed version.

## A worked example

Set up a weekly security audit agent for a Bun + TypeScript repo:

1. Store `GIT_TOKEN` in WorkerEnv.
2. Create the agent, bind `primary`/`coding`.
3. Author `MISSION.md`: "Every Monday, clone the repo. Run `bun audit` for dependency vulnerabilities. Scan source files for hardcoded secrets and injection patterns (eval, exec, SQL string concatenation). Report findings by severity: critical/high immediately to #security, medium/low in the weekly summary. Suggest remediation (upgrade version, fix pattern). Do not patch."
4. Add a weekly schedule: `cron: "0 8 * * 1"`.
5. The agent clones, audits, scans, classifies, and posts the report.

## What this guide is not

It is not a penetration tester — the agent scans source code and dependencies, not a running system. It is not a SAST replacement — the agent uses pattern matching and tool output, not formal data-flow analysis. And it is not a fix — it reports; the team fixes. For security-critical changes, a human review is always required.

## Next steps

- For git setup, read [Git integration](../git-integration/).
- For the shell tools (running audit commands), read [Code execution](../code-execution/).
- For security hardening of the Ankole installation itself, read [Security hardening](../security-hardening/).
- For scheduling, read [Cron schedules](../cron-schedules-ops/).
