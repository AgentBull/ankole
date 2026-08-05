# Tasks, OKRs, and attendance

## Tasks

Bot-useful shortcuts (`lark-cli task --help` lists the rest) include create, get/update, complete/reopen, assign, followers, comments, reminders, attachments, ancestors, tasklists, and tasklist membership when command help lists bot.

```bash
lark-cli task +create --summary "Prepare weekly update" --assignee ou_xxx --idempotency-key <stable-key> --as bot --format json
lark-cli task tasks get --task-guid <task_guid> --as bot --format json
lark-cli task +update --task-id <task_guid> --summary "Prepare monthly update" --as bot --format json
lark-cli task +complete --task-id <task_guid> --as bot --format json
lark-cli task tasklists get --tasklist-guid <tasklist_guid> --as bot --format json
```

Confirm exact flags with help. The typed surface also covers tasks, tasklists, sections, subtasks, members, custom fields and options, and agent task-step information. Prefer an idempotency key for creates. Personal "my tasks", related-task, and search shortcuts are not assumed to work for the app; use explicit IDs or bot-capable typed endpoints.

## OKRs

The bot-capable surface (`lark-cli okr --help` lists the rest) includes cycles, objectives, key results, alignments, indicators, weights, ordering, and progress records.

```bash
lark-cli okr +cycle-list --user-id ou_xxx --user-id-type open_id --as bot --format json
lark-cli okr +cycle-detail --cycle-id <cycle_id> --as bot --format json
lark-cli okr +progress-list --target-type objective --target-id <objective_id> --as bot --format json
```

Inspect help for canonical IDs and flags. Read the current objective/key-result before patching content, score, deadline, weight, position, indicator values, or progress. Deletes and reorder operations require a precise target and confirmation when marked high risk.

## Attendance

Attendance support is intentionally query-oriented. Inspect the schema and pass explicit employee IDs and a bounded date range:

```bash
lark-cli schema attendance.user_tasks.query
lark-cli attendance user_tasks query --employee-type employee_id --data @attendance-query.json --as bot --format json
```

The endpoint may label the query as a write because it uses a POST request; treat it as a read of attendance results. Never infer that all employees are visible. Return invalid/out-of-scope users separately when the API provides that information.
