---
name: bullx-workflow
description: Use for BullX Agent implementation, debugging, review, and repository workflow tasks where current code and user-visible behavior must stay aligned.
default_enabled: true
tags:
  - bullx
  - development
  - workflow
category: engineering
---

# BullX Workflow

Start from the current implementation, not from a clean architecture guess. For BullX Agent work, keep user-visible digital-employee behavior first: the agent must be able to do the work, and secondary concerns such as audit, permissions, or version history must not block the core workflow.

When changing code, preserve the established Bun-first and PostgreSQL-backed runtime boundaries. Use the current DB schema, runtime services, and e2e harnesses as the source of truth.
