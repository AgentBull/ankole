# Expected Incompleteness

Formal traversal checks every term or state permitted by the untyped BEAM runtime or abstract state model. When an upstream caller contract, Ash resource attribute, or PostgreSQL constraint excludes a case, production code omits redundant defensive guards and formal laws declare the boundary in `requires:`.

Each entry below records an intentional boundary surfaced during formal verification and names the upstream owner that enforces it.

## `Ankole.Pod.Position`

- **Production module**: `app/control_plane/lib/ankole/pod/position.ex`
- **Law suite**: `tools/formal/test/pod/position_laws_test.exs`

| Surfaced Case | Runtime Behavior | Formal Scope | Upstream Owner |
| --- | --- | --- | --- |
| `Position.between/2` receives `false` or another non-`nil` non-binary term (`integer()`, `atom()`, `tuple()`, unaligned `bitstring()`) | `lower = lower \|\| ""` coerces `lower = false` to `""` (treating `false` like an open lower bound instead of returning `:error`); other non-`nil` non-binary terms fall through `valid_nonempty?/1` as `false`. | `spec_bound?/1` restricts `lower` and `upper` to `nil` or aligned `binary()`. | `Ankole.Pod.Pages.place/2` and `Ankole.Pod.Pages.next_position/2` (`app/control_plane/lib/ankole/pod/pages.ex`) are the only callers. Both pass `nil` or `Page.position` (`pages.position text COLLATE "C" NOT NULL`, Ash `:string` with `allow_nil?: false` in `app/control_plane/lib/ankole/pod/page.ex`). |
| `Position.between/2` receives raw bytes without a separate `String.valid?/1` UTF-8 check | `valid?/1` checks that every byte is in `[0-9A-Za-z]` and returns `:error` for non-alphabet bytes such as `<<0xFF>>`. | `spec_valid_key?/1` models keys as `List UInt8` over ASCII `[0-9A-Za-z]` with lexicographic byte order (`PositionProof.compare_bin`). Every `[0-9A-Za-z]+` byte sequence is valid ASCII and valid UTF-8. | PostgreSQL `pages.position` (`text COLLATE "C" NOT NULL` in `app/control_plane/priv/repo/migrations/20261017110000_create_pod_content.exs`) enforces UTF-8 text on write and orders keys by byte value under `C` collation, matching BEAM binary `<`. |
| `Position.sequence/1` receives a non-integer term greater than `0` (such as `1.5` or `:a`) | `when count > 0` uses Erlang term comparison without `is_integer(count)`, so non-integer inputs raise `ArithmeticError` in `div/2` or `rem/2`. | `count` is a positive integer (`count >= 1`). | `Ankole.Pod.Pages.renumber/2` (`app/control_plane/lib/ankole/pod/pages.ex`) is the only caller and passes `length(siblings) + 1`, which is always an integer `>= 1`. |

## `Ankole.Sessions.WorkerAcquisition`

- **Production module**: `app/control_plane/lib/ankole/sessions/worker_acquisition.ex`
- **Law suite**: `tools/formal/test/sessions/worker_acquisition_laws_test.exs`

| Surfaced Case | Runtime Behavior | Formal Scope | Upstream Owner |
| --- | --- | --- | --- |
| `WorkerAcquisition.next/3` (`:expired`) or `WorkerAcquisition.timers/2` receives non-integer `now` or `since`, or `now < since` | `now - since` raises `ArithmeticError` on non-integer terms, and `max(60_000 - (now - since), 0)` exceeds `60_000` when `now < since`. | `valid_state?/1` requires integer `since`, and timer and transition laws require integer `now` with `now >= state_since(state)`. | `Ankole.Sessions.Turn` (`app/control_plane/lib/ankole/sessions/turn.ex`) is the only caller and passes `System.monotonic_time(:millisecond)`, which is a monotonically non-decreasing integer. |
| `WorkerAcquisition.phase_key/1` receives a term outside `:starting \| :resuming \| :retrying \| :replacing \| :capacity \| :preparing` | Raises `FunctionClauseError`. | Waiting states in `valid_state?/1` restrict `phase` to those six atoms. | `WorkerAcquisition.next/3` and `Ankole.AgentWorkers.workspace_status/1` (`app/control_plane/lib/ankole/agent_workers.ex`) construct every waiting phase atom. |

## `Ankole.AgentWorkers.ProviderKind` and `Ankole.AgentWorkers.Decision`

- **Production modules**: `app/control_plane/lib/ankole/agent_workers/provider_kind.ex`, `app/control_plane/lib/ankole/agent_workers/decision.ex`
- **Law suite**: `tools/formal/test/agent_workers/decision_laws_test.exs`

| Surfaced Case | Runtime Behavior | Formal Scope | Upstream Owner |
| --- | --- | --- | --- |
| `ProviderKind.current_instance?/2` receives non-map terms or maps without `:generation` and `:instance_ref` | Map dot access can raise `BadMapError` or `KeyError`. | `has_worker_observation_keys?/2` requires maps that contain `:generation` and `:instance_ref`. | `Ankole.AgentWorkers.ReconcileJob` (`app/control_plane/lib/ankole/agent_workers/reconcile_job.ex`) passes `%Ankole.AgentWorkers.AgentWorker{}` structs and `ProviderKind.observation()` maps from provider adapters. |
| `Decision.next/1` receives a non-list collection or malformed observations | Enumeration or field access can fail. | `cleanup_input?/1` requires a fact map with `:worker` and `:objects`; `observation_list?/2` requires a proper list and the matcher keys. The cleanup law also requires a cleanup candidate. Other fact fields are unrestricted. | `ReconcileJob.observe/1` obtains a list from the provider's `list_instances/2` callback. `ReconcileJob.facts/6` supplies that list and the Worker row to `Decision.next/1`. No-cleanup lifecycle decisions are outside this law's scope, not invalid production inputs. |
| `Decision.pause_release?/2` receives a non-map `definition`, a map without `:pause`, or a non-boolean `definition.pause` | `definition.pause and ...` raises `BadMapError`, `KeyError`, or `BadBooleanError`. | `has_boolean_pause?/1` requires a map with a boolean `:pause` entry. | Each trusted provider implements `kind.definition/0` and supplies a boolean `pause` field under the `ProviderKind.Definition.t()` contract. A struct or typespec alone does not enforce that field type. |

## `Ankole.Text`

- **Production module**: `app/control_plane/lib/ankole/text.ex`
- **Law suite**: `tools/formal/test/text_laws_test.exs`

| Surfaced Case | Runtime Behavior | Formal Scope | Upstream Owner |
| --- | --- | --- | --- |
| `Text.truncate_utf8/3` receives `byte_size(text) > max_bytes` and `byte_size(suffix) > max_bytes` | `available = max(max_bytes - byte_size(suffix), 0)` is `0`, and `"" <> suffix` returns `suffix` with `byte_size(suffix) > max_bytes`. | `truncate_utf8_universal_contract` requires `max_bytes >= byte_size(suffix)` and valid UTF-8 `text` and `suffix`. | `Ankole.BackgroundAgentJobs.Wakeups.truncate_summary/1` (`app/control_plane/lib/ankole/background_agent_jobs/wakeups.ex`) is the only production caller and passes `max_bytes = 16_384` with `suffix = "...[truncated]"` (`14` bytes). Callers with arbitrary byte budgets call `Text.truncate_utf8_window/3`. |
| `Text.utf8_suffix/2` receives an invalid UTF-8 binary with `byte_size(text) <= max_bytes`, a non-binary `_text` with `max_bytes == 0`, or a non-integer `max_bytes` | `when byte_size(text) <= max_bytes` returns `text` without checking `String.valid?(text)` or `is_integer(max_bytes)`, and `def utf8_suffix(_text, 0)` returns `""` without checking `is_binary(_text)`. | `utf8_suffix_universal_contract` requires `is_binary(text)`, `String.valid?(text)`, `is_integer(max_bytes)`, and `max_bytes >= 0`. | `Text.truncate_utf8_window/3` (`app/control_plane/lib/ankole/text.ex`) and `Ankole.AutomationJobs.bounded_text/2` (`app/control_plane/lib/ankole/automation_jobs.ex`) are the only callers and pass valid `String.t()` values with non-negative integer byte budgets. |

## Reply interaction normalization and merge

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| Every map with `"state" => "answered"` must be absorbing, even without an answer or with an empty choice value. | Excluded malformed checkpoint. The normalizer drops this entry, so a later pending entry can replace it. `ClarifyPrompt.normalize_choice/2` constructs nonempty choice IDs and values from required labels; the native resolution includes the constructed answer. Provider callbacks normalize and match the answer before resolution. No production guard is added for a forged terminal map. | `conversations/delivery/clarify_prompt.ex`, `reply_presentation.ex`, `interactions.ex`, `interaction_state.ex` |
| An answered free-text value is empty. | Expected valid input when the native reply has attachments. It must remain terminal. The valid-state traversal includes this case. | `Interactions.native_answer/3` |
| A later valid terminal answer replaces an earlier terminal answer. | Rejected candidate. The durable first terminal result wins when `merge_checkpoint/3` combines writes that span provider I/O. The direct Lean law proves resolution refusal; merge itself has a finite production-state traversal, not a general Lean theorem. | `PreviewStates.put_checkpoint_in_tx`, `InteractionState.merge_checkpoint/3` |

## Activity stream ordering

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| Every accepted snapshot increases revision. | Expected counterexample: a settled snapshot at the same epoch can have a lower revision than an active snapshot. Settlement is authoritative and closes the epoch. A diagnostic `unavailable` snapshot can also update state without advancing revision. | `ankole_web/pod_stream.ex`, `sessions/activity.ex` |
| An equal-revision active snapshot always remains stale. | Expected exception: a fresh read can recover an unavailable display at the same watermark. An asynchronous event cannot use that exception. | `PodStream.merge_activity/3` and `snapshot_frames` |
| Epoch zero always denotes an older snapshot. | Expected exception: a failed diagnostic read has no epoch. The merge copies the current epoch and keeps the maximum revision before comparison. | `PodStream.merge_activity/3` |
| Pure merge must reject a publisher from an old Driver process. | Outside the pure function. `activity/5` checks Agent UID, Session ID, the current Driver PID, the retired PID, and `Activity.valid?/1` before merge. | `PodStream.activity/5` |

## Formula dependency and copy boundaries

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| Validation preserves the original list order. | Expected counterexample: a consumer placed before its dependency must move after it. The finite graph traversal checks dependency order and complete field coverage instead. | `Formula.dependency_order/2`, `Formula.validate_all/1` |
| Duplicate field IDs remain separate definitions. | Excluded by the database primary key and the table field reader. `Map.new/2` selects one duplicate in a synthetic list. | `Pod.BaseField`, `Bases.fields`, `Pod.Copy.copy_fields/2` |
| Missing entries in a copy mapping are ignored. | Rejected candidate. `Map.fetch!/2` requires a complete mapping. Copy builds it from all source definitions before validation and remapping; Copy generates IDs with `Ankole.Ecto.UUIDv7`, and the database enforces uniqueness. | `Pod.Copy.copy_fields/2`, `Formula.remap_references/2` |
| A missing reference or a reference cycle can reach SQL evaluation. | Production validation rejects these with `:unknown_formula_field` or `:formula_cycle`. The 512-graph traversal checks all self-loops and cycles for three nodes. This bound is not a theorem for arbitrary graph size. | `Formula.validate_all/1`; `pod/formula_plan_test.exs` tests the actual SQL plan and lazy evaluation |

## File path and action boundaries

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| Calling `required_read_action/2` directly on `dist/../server/main.ts` must return forbidden. | Excluded at this internal call. `page_path/2` calls `Files.Path.normalize/1` before file classification; dot, parent, and empty segments are invalid. The classifier consumes normalized relative paths. | `Pod.Files.resolve_read/4`, `Pod.Files.page_path/2` |
| Percent escapes and backslashes must be decoded or treated as filesystem traversal. | Rejected candidate for the drive key contract. The normalizer checks literal UTF-8 keys with `/` as separator; it does not URL-decode or resolve host filesystem paths. Transport decoding belongs to the route before this boundary. | `Files.Path.normalize/1`, `Pod.Files.parse_path/1`, `Drive` |
| Source/config files are readable with page view. | Rejected candidate. `src/`, `server/`, and the four fixed configuration files require page edit. Page view covers `dist/` and `assets/`. Authorization and digest validation still run inside the read transaction. | `Pod.Files.required_read_action/2`, `resolve_read/4` |

## ACL graph, Usersets, and editor moves

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| A standalone manage bit implies view, edit, and write-records bits. | Expected counterexample. Individual actions are independent. Role expansion creates the aggregate masks 1, 3, 7, and 15; Usersets can refer to one source action. | `Pod.Access.actions/1`, `Pod.Access.Graph` |
| A Userset cycle grants permission without a seed. | Rejected candidate. Positive reachability needs a seed. The Lean model proves this for arbitrary graphs, including cycles. | `Graph` recursive reach query |
| Keeping the requesting editor's permissions makes a move safe for everyone. | Expected counterexample: other subjects or groups can gain or lose access. The move must preserve the symbolic incoming policy for all actors. Conditional grants or dependence on the moving page can return `:unproven` and reject the move. | `Access.move_preserves_permissions?/3`, `symbolic_graph/4` |
| Every inherited node can be removed from the ACL graph. | Excluded unless it is a transparent anchor: no local seed, one inherited dependency, and the same action/scope and visibility conditions. These are assumptions of the contraction theorem, not a proof that SQL extraction always supplies them. | `pages` anchor constraints, `Graph`, `anchor_property_test.exs` |

## Human access, credential release, and OTP

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| The latest suspension reason can erase an earlier offboarding. | Rejected candidate. The current disabled cycle uses offboard restrictions, including restrictions cleared after the latest restore. A later suspension does not restore credentials. | `HumanAccess.offboarded_in_current_cycle?/1` |
| A challenge started at the same timestamp as credential release is current. | Expected denial. The comparison is strict `:gt`; equality does not establish that proof started after release. | `SiteCredentials.claim_current?/1` |
| Failing Pod membership or account completion should restore the used OTP. | Expected counterexample. Consumption commits before completion in a separate transaction, so the same valid code cannot be reused after a downstream rejection. | `Authn.Strategies.Otp.Actions.verify_with/6` |
| Restarting the process restores a challenge's attempts. | Rejected candidate. Attempt count, expiry, and consumption are stored in the locked challenge row. The process rate limiter is additional admission control. | `verify_locked/3`, `live?/2`, challenge resource |

## Automation Attempt write authority

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| An actor authorized earlier can always commit later. | Expected counterexample: a new attempt, inactive Job/Run, or changed Human access version invalidates it. The write checks current authority in the transaction that performs the write. | `AttemptAccess.authorize_actor_in_tx/2`, `Pod.Access.write/3` |
| A service Job needs a Human version, or a review-required Job can use the service path. | Rejected candidates. Service authorization has no Human; review-required authorization fails. | `AttemptAccess.human/1`, `WorkAccess.check_in_tx/1`, Job authorization constraint |
| A Human lock from a snapshot can authorize a reassigned active Job. | Excluded by the current reauthorization actions: an active human-authorized Automation Job cannot switch authorizers through the review action. The model still assumes that the Human/Job/Run locks and action rules hold until commit; it does not prove lock scheduling. | `WorkAccess.classify_in_tx/5`, `reauthorizable?/2`, `AttemptAccess` |

## Applet lifecycle

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| Any failed connection can safely retry an invocation. | Expected counterexample after `start`: a capability write can already have committed. Retry is limited to one admission connection failure or HTTP 503 before user execution starts. | `AppletClient.connect/6`, `retryable?/1`, `start/4` |
| Admission failover gets a new timeout budget. | Rejected candidate. Preflight, code upload, upgrade, and failover share the original absolute deadline. | `AppletClient` deadline argument |
| A failed cleanup request replaces a received completed result. | Rejected candidate. Completion and cancellation survive cleanup failure; late frames do not replace the first terminal outcome. | `AppletClient.settle/3`, `frames/5` |
| Cancellation undoes committed capability writes. | Expected counterexample. Cancellation stops owned tasks; each completed capability transaction has independent durable meaning. Neither the model nor the production contract promises rollback across capability calls. | `Pod.Applets.Invocation`, `Capabilities`, `Pod.Access.write/3` |

## Base promotion, DDL, and deletion

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| A successful control-plane `SELECT 1` makes two database commits atomic. | Expected counterexample: the process or connection can fail after the probe or shard commit and before the metadata commit. These are separate transactions. The model includes this state. | `BaseRepo.run/3`; `PodContentModel.md` storage contract |
| Residual physical rows are authoritative after an interrupted inline promotion. | Rejected candidate. Until metadata commits, the inline rows remain authoritative. A retry drops residual shard objects and imports the current inline snapshot. | `Promote.if_needed/1`, `Physical.create_table!/3` |
| A partial DDL commit can serve data with the previous metadata schema. | Rejected candidate. A schema-version mismatch denies access and requires operator repair. No automatic inverse-DDL recovery is promised. | `Physical.state/2`, `BaseRepo`, `PodContentModel.md` |
| A crash between shard drop and metadata deletion makes cleanup non-repeatable. | Rejected candidate. Deletion is marked and queued first; marked tables are hidden; physical drop and metadata removal can repeat. Eventual completion assumes the cleanup job runs. | `Bases.Delete`, `Pod.Jobs.PurgePage` |
