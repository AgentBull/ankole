# Expected Incompleteness

During formal verification, Lynx and Lean explore every term or state permitted by the untyped BEAM runtime or by an abstract state model. Whenever an upstream caller contract, Ash resource attribute, or PostgreSQL constraint rules out an invalid case, production code omits redundant defensive guards and the formal laws state that boundary explicitly in `requires:`.

Each entry below documents an intentional boundary surfaced during formal verification and identifies the upstream owner responsible for enforcing it. A dated decision records a boundary the project agreed to keep rather than close.

## `Ankole.Pod.Position`

- **Production module**: `app/control_plane/lib/ankole/pod/position.ex`
- **Law suite**: `tools/formal/test/pod/position_laws_test.exs`

| Surfaced Case | Runtime Behavior | Formal Scope | Upstream Owner |
| --- | --- | --- | --- |
| `Position.between/2` receives `false` or another non-`nil` non-binary term (`integer()`, `atom()`, `tuple()`, unaligned `bitstring()`) | `lower = lower \|\| ""` coerces `lower = false` to `""` (treating `false` like an open lower bound instead of returning `:error`), while other non-`nil` non-binary terms fall through `valid_nonempty?/1` as `false`. | `spec_bound?/1` restricts `lower` and `upper` to `nil` or aligned `binary()`. | `Ankole.Pod.Pages.place/2` and `Ankole.Pod.Pages.next_position/2` (`app/control_plane/lib/ankole/pod/pages.ex`) are the sole callers, and both pass either `nil` or `Page.position` (`pages.position text COLLATE "C" NOT NULL`, declared as Ash `:string` with `allow_nil?: false` in `app/control_plane/lib/ankole/pod/page.ex`). |
| `Position.between/2` receives raw bytes without a separate `String.valid?/1` UTF-8 check | `valid?/1` checks that every byte falls in `[0-9A-Za-z]` and returns `:error` for non-alphabet bytes such as `<<0xFF>>`. | `spec_valid_key?/1` models keys as `List UInt8` over ASCII `[0-9A-Za-z]` ordered lexicographically by byte (`PositionProof.compare_bin`); every `[0-9A-Za-z]+` byte sequence is valid ASCII and therefore valid UTF-8. | On write, PostgreSQL column `pages.position` (`text COLLATE "C" NOT NULL` in `app/control_plane/priv/repo/migrations/20261017110000_create_pod_content.exs`) requires valid UTF-8 text and sorts keys by raw byte value under `C` collation, matching BEAM binary `<`. |
| `Position.sequence/1` receives a non-integer term greater than `0` (such as `1.5` or `:a`) | `when count > 0` uses Erlang term ordering without `is_integer(count)`, so non-integer inputs raise `ArithmeticError` inside `div/2` or `rem/2`. | `count` is constrained to a positive integer (`count >= 1`). | `Ankole.Pod.Pages.renumber/2` (`app/control_plane/lib/ankole/pod/pages.ex`) is the sole caller and passes `length(siblings) + 1`, which is always an integer `>= 1`. |

## `Ankole.Sessions.WorkerAcquisition`

- **Production module**: `app/control_plane/lib/ankole/sessions/worker_acquisition.ex`
- **Law suite**: `tools/formal/test/sessions/worker_acquisition_laws_test.exs`

| Surfaced Case | Runtime Behavior | Formal Scope | Upstream Owner |
| --- | --- | --- | --- |
| `WorkerAcquisition.next/3` (`:expired`) or `WorkerAcquisition.timers/2` receives non-integer `now` or `since`, or `now < since` | `now - since` raises `ArithmeticError` on non-integer terms, and `max(60_000 - (now - since), 0)` exceeds `60_000` when `now < since`. | `valid_state?/1` requires an integer `since`, and timer and transition laws require an integer `now` satisfying `now >= state_since(state)`. | `Ankole.Sessions.Turn` (`app/control_plane/lib/ankole/sessions/turn.ex`) is the sole caller and supplies `System.monotonic_time(:millisecond)`, which is a monotonically non-decreasing integer. |
| `WorkerAcquisition.phase_key/1` receives a term outside `:starting \| :resuming \| :retrying \| :replacing \| :capacity \| :preparing` | Raises `FunctionClauseError`. | Waiting states in `valid_state?/1` restrict `phase` to those six atoms. | `WorkerAcquisition.next/3` and `Ankole.AgentWorkers.workspace_status/1` (`app/control_plane/lib/ankole/agent_workers.ex`) construct all waiting-phase atoms. |

## `Ankole.AgentWorkers.ProviderKind` and `Ankole.AgentWorkers.Decision`

- **Production modules**: `app/control_plane/lib/ankole/agent_workers/provider_kind.ex`, `app/control_plane/lib/ankole/agent_workers/decision.ex`
- **Law suite**: `tools/formal/test/agent_workers/decision_laws_test.exs`

| Surfaced Case | Runtime Behavior | Formal Scope | Upstream Owner |
| --- | --- | --- | --- |
| `ProviderKind.current_instance?/2` receives non-map terms or maps missing `:generation` and `:instance_ref` | Map dot access raises `BadMapError` or `KeyError`. | `has_worker_observation_keys?/2` requires maps containing both `:generation` and `:instance_ref`. | `Ankole.AgentWorkers.ReconcileJob` (`app/control_plane/lib/ankole/agent_workers/reconcile_job.ex`) passes `%Ankole.AgentWorkers.AgentWorker{}` structs alongside `ProviderKind.observation()` maps returned by provider adapters. |
| `Decision.next/1` receives a non-list collection or malformed observations | Enumeration or map field access fails at runtime. | `cleanup_input?/1` requires a fact map with `:worker` and `:objects`, `observation_list?/2` requires a proper list whose elements carry the matcher keys, and the cleanup law further requires at least one cleanup candidate (other fact fields remain unrestricted). | `ReconcileJob.observe/1` fetches the observation list from the provider's `list_instances/2` callback, and `ReconcileJob.facts/6` passes that list and the Worker row to `Decision.next/1`. Lifecycle decisions without cleanup candidates fall outside this specific law's scope rather than representing invalid production inputs. |
| `Decision.pause_release?/2` receives a non-map `definition`, a map missing `:pause`, or a non-boolean `definition.pause` | `definition.pause and ...` raises `BadMapError`, `KeyError`, or `BadBooleanError`. | `has_boolean_pause?/1` requires a map with a boolean `:pause` field. | Every first-party provider implements `kind.definition/0` and populates a boolean `pause` field under `ProviderKind.Definition.t()` (note that Elixir structs and typespecs alone do not enforce field types at runtime). |

## `Ankole.Text`

- **Production module**: `app/control_plane/lib/ankole/text.ex`
- **Law suite**: `tools/formal/test/text_laws_test.exs`

| Surfaced Case | Runtime Behavior | Formal Scope | Upstream Owner |
| --- | --- | --- | --- |
| `Text.truncate_utf8/3` receives `byte_size(text) > max_bytes` while `byte_size(suffix) > max_bytes` | `available = max(max_bytes - byte_size(suffix), 0)` evaluates to `0`, so `"" <> suffix` returns `suffix` even though `byte_size(suffix) > max_bytes`. | `truncate_utf8_universal_contract` requires `max_bytes >= byte_size(suffix)` along with valid UTF-8 `text` and `suffix`. | `Ankole.BackgroundAgentJobs.Wakeups.truncate_summary/1` (`app/control_plane/lib/ankole/background_agent_jobs/wakeups.ex`, `max_bytes = 16_384`, `suffix = "...[truncated]"`, `14` bytes) and `Ankole.Brain.PageEdit.compact_diff/2` (`app/control_plane/lib/ankole/brain/page_edit.ex`, `max_bytes = 8_192`, `suffix = "\n... (diff truncated)"`, `21` bytes) are the sole production callers. Callers with arbitrary byte budgets use `Text.truncate_utf8_window/3` instead. |
| `Text.utf8_suffix/2` receives an invalid UTF-8 binary with `byte_size(text) <= max_bytes`, a non-binary `_text` with `max_bytes == 0`, or a non-integer `max_bytes` | `when byte_size(text) <= max_bytes` returns `text` without checking `String.valid?(text)` or `is_integer(max_bytes)`, and `def utf8_suffix(_text, 0)` returns `""` without checking `is_binary(_text)`. | `utf8_suffix_universal_contract` requires `is_binary(text)`, `String.valid?(text)`, `is_integer(max_bytes)`, and `max_bytes >= 0`. | `Text.truncate_utf8_window/3` (`app/control_plane/lib/ankole/text.ex`) and `Ankole.AutomationJobs.bounded_text/2` (`app/control_plane/lib/ankole/automation_jobs.ex`) are the sole callers, passing valid `String.t()` binaries and non-negative integer byte budgets. |

## Reply interaction normalization and merge

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| Every map containing `"state" => "answered"` is absorbing, even when the answer is missing or a choice value is empty. | Excluded malformed checkpoint: the normalizer drops malformed answered entries so a subsequent pending entry can replace them. `ClarifyPrompt.normalize_choice/2` builds nonempty choice IDs and values from required labels, native resolution attaches the constructed answer, and provider callbacks normalize and match answers prior to resolution. Production code adds no extra guard against forged terminal maps. | `conversations/delivery/clarify_prompt.ex`, `reply_presentation.ex`, `interactions.ex`, `interaction_state.ex` |
| An answered free-text value is empty. | Valid terminal input when a native reply carries attachments without body text; it must remain terminal, and the valid-state traversal covers this case. | `Interactions.native_answer/3` |
| Whether a later valid terminal answer overwrites an earlier terminal answer. | Rejected candidate: when `merge_checkpoint/3` reconciles concurrent writes across provider I/O, the first durable terminal answer wins. The Lean law proves that resolved states reject further resolution, while a finite traversal over production states verifies `merge_checkpoint/3` (without a general Lean theorem over arbitrary maps). | `PreviewStates.put_checkpoint_in_tx`, `InteractionState.merge_checkpoint/3` |

## Activity stream ordering

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| Every accepted snapshot strictly increases revision. | Expected counterexample: within the same epoch, an authoritative settled snapshot closes the epoch even if its revision is lower than a prior active snapshot, and a diagnostic `unavailable` snapshot can update display state without advancing the revision. | `ankole_web/pod_stream.ex`, `sessions/activity.ex` |
| Whether an active snapshot at the current revision is always rejected as stale. | Expected exception: a synchronous fresh read can recover an `unavailable` display at the same watermark, whereas an asynchronous event cannot. | `PodStream.merge_activity/3` and `snapshot_frames` |
| Whether epoch zero always indicates an older snapshot. | Expected exception: a failed diagnostic read carries no epoch, so `PodStream.merge_activity/3` copies the current epoch and preserves the maximum revision before comparing snapshots. | `PodStream.merge_activity/3` |
| Pure merge must reject snapshots published by a retired Driver process. | Enforced outside the pure merge function: `PodStream.activity/5` verifies Agent UID, Session ID, current Driver PID, retired Driver PID, and `Activity.valid?/1` before calling `merge_activity/3`. | `PodStream.activity/5` |

## Formula dependency and copy boundaries

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| Validation preserves the caller's input list order. | Expected counterexample: if a formula appears before a field that it depends on, dependency sorting moves it after that dependency. The finite graph traversal verifies topological dependency order and complete field preservation instead. | `Formula.dependency_order/2`, `Formula.validate_all/1` |
| Duplicate field IDs remain distinct definitions. | Excluded upstream by the database primary key and table field reader; in synthetic lists, `Map.new/2` collapses duplicate keys to a single entry. | `Pod.BaseField`, `Bases.fields`, `Pod.Copy.copy_fields/2` |
| Missing entries in a copy ID mapping are silently skipped. | Rejected candidate: `Map.fetch!/2` requires a complete old-to-new ID map. `Pod.Copy.copy_fields/2` populates keys for every source field using `Ankole.Ecto.UUIDv7` (backed by database uniqueness constraints) before validating and remapping formulas. | `Pod.Copy.copy_fields/2`, `Formula.remap_references/2` |
| Whether a missing field reference or dependency cycle can reach SQL evaluation. | Rejected during validation with `:unknown_formula_field` or `:formula_cycle`. Exhaustive traversal across all 66,066 directed graphs with one to four nodes verifies rejection of self-loops and cycles up to four nodes (bounded check rather than a proof for arbitrary graph sizes). | `Formula.validate_all/1`; `pod/formula_plan_test.exs` exercises SQL planning and lazy evaluation |

## Base patches and field versions

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| Every raw key survives a record patch, including empty values. | Narrowed to canonical persisted values: `Values.clean/1` removes `nil`, empty strings, and empty lists. Zero and false remain real values. The PostgreSQL tests preserve untouched canonical data and explicitly update fields to zero and false. | `Pod.Values.clean/1`, `Bases.Records.update_records/2` |
| Every field anywhere in the row needs a matching expected version. | Too restrictive for independent edits. The check covers the union of patched keys and explicitly supplied expected-version keys; unrelated changes can coexist. The 5,103-case traversal also checks expected versions supplied for fields outside the patch. | `Bases.Records.field_cas/3` |
| Missing versions are always invalid. | A never-written field has no stored version. Missing and nil lookups can legitimately match on its first write. Production creates and increments integer versions; the bounded matrix includes missing entries and two successive integer values. The universal acceptance theorem needs only map inputs. | `Bases.Records.create_records/2`, `update_records/2`, `field_cas/3` |
| Any field update leaves every other stored fact unchanged. | Too broad for reverse links, derived fields, row timestamps, and table counters. The frame checks concern independent ordinary fields and unrelated rows; the batch rollback checks compare committed rows and table counters. | `Bases.Records.maintain_links/5`, `Bases.Write`, `Values` |
| A rejected batch can leave its earlier creates or updates committed. | Violates the ordinary atomic write contract. Both real storage tests attempt a create and valid update before a stale update and verify unchanged stored rows, record count, and data version. This is adapter evidence, not a Lean proof of PostgreSQL or a distributed transaction theorem. | `Bases.write_records`, `BaseRepo.run`, `base_storage_test.exs` |

## Tool call and result identity

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| `call_id` alone identifies every result. | Insufficient when a program and a direct call reuse an ID. Pair identity includes caller scope. The acceptance theorem uses the actual production `pair_key/1`, and bounded sequences include direct and program-scoped calls with the same ID. | `AIGateway.ResponseItems.pair_key/1`, `caller_scope/1` |
| Any duplicate should fail, or the last duplicate should win. | Identical retries carry no new information and can be deduplicated. Distinct payloads for the same identity are ambiguous and must be quarantined. The independent sequence oracle compares full output items, so a conflicting result cannot silently replace an earlier result. | `ToolResultJournal.deduplicate_tool_result_items/1`, `reconcile_tool_result_items/2` |
| Any well-formed output can be attached to the current response. | Rejected: an executable matching call, compatible result type, and compatible optional name are required. Orphans and mismatches are checked by bounded traversal and existing production persistence tests. | `ResponseItems.validate_client_call_output/2`, `ToolResultJournal.reconcile_tool_result_items/2` |
| A successful identity proof establishes termination, all valid-input acceptance, arbitrary-length journal deduplication, or exactly-once execution of remote tools. | Outside the theorem. The implication covers production validation that returns `:ok`; a closed accepted witness establishes non-vacuity under the Lean runtime. Cutoffs for non-list enumeration and error inspection cannot satisfy a successful precondition. Journal sequences and persistence are checked separately. | `tool_result_laws_test.exs`; real AIGateway suites |

## PTC replay and transport ordering

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| Replaying a memo permits external tool side effects to execute exactly once across crashes. | Too strong. The runner reuses matching memo results and emits only unanswered calls. Persistence, delivery, and external idempotency remain separate obligations. The finite replay traversal executes the production-generated worker; it does not prove arbitrary programs deterministic or replace native isolation tests. | `function_runtime/main/ptc_bootstrap.ts`, `FunctionRuntime.ProgramRunner`, AIGateway program journal |
| Catching a replay mismatch or pending-limit exception lets a program publish its remaining pending calls. | Violates the step contract. Failure remains sticky and the terminal response contains no pending calls. The bounded cases exercise caught exceptions, sequential calls, and `Promise.all`; real runtime tests check the HTTP boundary. | `ptcWorker` failure state and `finish` |
| Credit must never be exceeded by any push. | Too strict: when no push is in flight, `StreamWindow.fits` allows one probe to refresh exhausted credit. The independent maximum envelope size still applies. A cumulative ACK describes sequence completion, not an earlier push's business success. | `channel_transport.ts` `StreamWindow.fits`, `sendEnvelope`, `applyReply` |
| A completed sequence below the current ACK must remain absent after arbitrary repeated calls to the private ACK helper. | The Channel supplies completions from its accepted operations. The traversal checks unique completion orders and sets above the current ACK; injecting arbitrary stale completions into this private helper does not establish a production bug. The Lean gap theorem uses actual map-backed `MapSet` membership; tuple-backed OTP sets and the successor-present deletion path are cut off for that theorem. Its empty-set witness reaches neither cutoff. | `WorkerChannel.accept/6`, `complete/4`, `advance_acked/2` |
| A bounded callback traversal proves every scheduler behavior or guarantees eventual delivery. | Excluded. The Worker suite checks the stated event permutations with the production transport and its existing unit socket adapter. Some duplicate/late callback combinations are deliberately stronger than Phoenix's usual single-reply behavior; they are not evidence that such combinations occur on the network. | `fabric.test.ts`, real Phoenix WebSocket integration suite |

## Provider tool aliases

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| Flattening every possible `(namespace, name)` is injective. | Impossible for a bounded wire name, and unnecessary. Root `alpha__lookup` and namespaced `alpha.lookup` can intentionally produce the same alias. Adapters must reject colliding declarations before sending a request. No hash-collision assumption is needed for that acceptance rule. | `tool_identity.rs`, `reject_duplicate_emulated_tool_names` |
| Anthropic may accept a custom declaration and return a function call for it. | Confirmed production bug during the bounded traversal with a single valid namespaced custom tool. `ToolContract` permits custom tools and `Providers.Claude` forwards them to this resolver. Anthropic uses the shared text-input schema and restoration helpers across complete responses, streamed items, explicit choices, and replay. The regression checks preserve the declared type and raw text. | `anthropic.rs`, `custom_tool_emulation.rs`, `tests/tool_identity.rs` |
| Every raw kernel tool name in the traversal is accepted by public APIs. | Not claimed. The 16 declarations include Unicode and overlength names to exercise the kernel's wire encoding; `ToolContract.validate_responses_identifiers/1` enforces the public Responses identifier boundary. The confirmed custom-tool counterexample uses ordinary valid names. Unknown tools returned by a provider remain subject to downstream call validation. | `AIGateway.ToolContract`, `tool_identity.rs` |
| Passing the Rust traversal establishes a universal proof over all strings, all providers, or a handwritten alias model. | Excluded. The oracle obtains isolated wire names from the actual adapters, checks their composition and reversal, and enumerates the documented finite declaration family for Chat Completions and Anthropic only. It neither installs a second implementation nor proves BLAKE3. | `bounded_tool_sets_reject_alias_collisions_or_roundtrip_every_identity` |

## Aggregate reference byte budget

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| Negative additions refund budget or non-integers count as sizes. | Outside the caller contract: reference hydration passes stored artifact byte sizes and starts the accumulator at zero. The function guard rejects malformed inputs. Both laws require nonnegative integers. | `AIGateway.Artifacts.References.consume_reference_bytes/2`, `ReferenceBudget.consume/2` |
| Each attachment can independently receive the full request budget. | Violates aggregate accounting. The composition law proves that splitting an addition cannot change acceptance or the final sum. Actual callers must thread the returned accumulator and supply true byte sizes; these obligations are not a proof of the hydration loop. | `Artifacts.References`, `ReferenceBudget.consume/2` |
| Formal verification determines that 100 MiB is the optimal product limit. | Excluded as a product tradeoff. The proof verifies correct accounting against the production limit and exact-boundary behavior; it does not choose the limit. | `ReferenceBudget` and the existing image byte-limit production test |

## File path and action boundaries

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| Calling `required_read_action/2` directly on `"dist/../server/main.ts"` returns forbidden. | Excluded before this internal helper runs: `Pod.Files.page_path/2` normalizes paths via `Files.Path.normalize/1`—rejecting `.`, `..`, and empty segments—before passing normalized relative paths to `required_read_action/2`. | `Pod.Files.resolve_read/4`, `Pod.Files.page_path/2` |
| Percent-encoded escapes and backslashes are decoded or treated as host path traversal. | Rejected candidate for drive object keys: `Files.Path.normalize/1` validates literal UTF-8 keys delimited by `/` without URL-decoding or resolving host filesystem paths. HTTP routes decode URL parameters before crossing into this boundary. | `Files.Path.normalize/1`, `Pod.Files.parse_path/1`, `Drive` |
| Source and configuration files are readable with page-view permission. | Rejected candidate: reading `src/`, `server/`, or any of the four fixed configuration files requires page-edit permission, whereas page-view permission covers only `dist/` and `assets/`. Authorization and digest checks run inside the read transaction. | `Pod.Files.required_read_action/2`, `resolve_read/4` |

## ACL graph, Usersets, and editor moves

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| Whether a standalone `manage` bit implies `view`, `edit`, and `write-records` bits. | Expected counterexample: individual action bits remain independent so Usersets can target a single source action, whereas role expansion explicitly emits the cumulative bitmasks `1`, `3`, `7`, and `15`. | `Pod.Access.actions/1`, `Pod.Access.Graph` |
| Whether a Userset cycle can grant permission without a direct seed. | Rejected candidate: positive reachability always requires at least one seed, which the Lean model proves for arbitrary graphs including cycles. | `Graph` recursive reach query |
| Whether preserving the requesting editor's own permissions makes a page move safe for everyone. | Expected counterexample: moving a page could still grant or revoke access for other subjects or groups, so a move must preserve the symbolic incoming policy across all actors. Conditional grants or policies tied to the moving page can return `:unproven`, causing Ankole to reject the move. | `Access.move_preserves_permissions?/3`, `symbolic_graph/4` |
| Every inherited node can be contracted out of the ACL graph. | Valid only for transparent anchors—nodes with no local seed, a single inherited dependency, and identical action/scope and visibility conditions. The contraction theorem assumes these properties rather than proving that SQL graph extraction always produces them. | `pages` anchor constraints, `Graph`, `anchor_property_test.exs` |

## Human access, credential release, and OTP

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| Whether a later suspension reason erases an earlier offboarding. | Rejected candidate: throughout the current disabled cycle, `HumanAccess.offboarded_in_current_cycle?/1` enforces offboard restrictions—even those cleared after the latest restore—so a subsequent suspension never restores credentials. | `HumanAccess.offboarded_in_current_cycle?/1` |
| An authentication challenge started at the exact timestamp of credential release counts as current. | Expected denial: `SiteCredentials.claim_current?/1` compares timestamps with strict `:gt`, because timestamp equality cannot prove that the challenge began after credentials were released. | `SiteCredentials.claim_current?/1` |
| A failure in Pod membership or account completion restores the consumed OTP code. | Expected counterexample: `verify_with/6` commits OTP consumption in its own transaction before running account completion, preventing replay of a valid code after a downstream rejection. | `Authn.Strategies.Otp.Actions.verify_with/6` |
| Whether restarting a BEAM process resets an OTP challenge's attempt counter. | Rejected candidate: attempt counts, expiry, and consumption live on the locked challenge row in PostgreSQL, while the in-memory process rate limiter provides only supplementary admission control. | `verify_locked/3`, `live?/2`, challenge resource |

## Automation Attempt write authority

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| An actor authorized when an attempt started can always commit writes later. | Expected counterexample: starting a newer attempt, deactivating the Job or Run, or bumping the authorizing Human's access version invalidates prior authority. Every write re-verifies current authority inside the committing transaction. | `AttemptAccess.authorize_actor_in_tx/2`, `Pod.Access.write/3` |
| A service-authorized Job requires a Human version, or a review-required Job can execute through the service path. | Rejected candidates: service authorization binds no Human Principal, and review-required Jobs fail authorization until explicitly reviewed by a Human. | `AttemptAccess.human/1`, `WorkAccess.check_in_tx/1`, Job authorization constraint |
| A Human lock captured from a snapshot can authorize an active Job whose authorizer changed. | Excluded by reauthorization rules: an active human-authorized Automation Job cannot switch authorizers through the review action. The formal model assumes that Human, Job, and Run row locks and action invariants hold through commit rather than modeling PostgreSQL lock scheduling. | `WorkAccess.classify_in_tx/5`, `reauthorizable?/2`, `AttemptAccess` |

## Applet lifecycle

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| Any dropped connection can safely retry an Applet invocation. | Expected counterexample once `start` is sent: user code may already have committed a capability write. Retries are restricted to a single admission connection failure or HTTP `503` response prior to `start`. | `AppletClient.connect/6`, `retryable?/1`, `start/4` |
| Whether admission failover receives a fresh timeout budget. | Rejected candidate: preflight, code upload, WebSocket upgrade, and admission failover all share the single original absolute deadline. | `AppletClient` deadline argument |
| Whether a failed cleanup request overwrites a completed invocation result. | Rejected candidate: once an invocation reaches completion or cancellation, that first terminal result survives cleanup failures and ignores late frames. | `AppletClient.settle/3`, `frames/5` |
| Whether cancelling an invocation rolls back committed capability writes. | Expected counterexample: cancellation halts in-flight tasks owned by the invocation, whereas each completed capability call commits its own independent transaction. Neither the formal model nor production promises cross-capability rollback. | `Pod.Applets.Invocation`, `Capabilities`, `Pod.Access.write/3` |

## Base promotion, DDL, and deletion

| Candidate or surfaced case | Classification and business reason | Owner |
| --- | --- | --- |
| Whether a passing control-plane `SELECT 1` probe makes shard and metadata commits atomic. | Expected counterexample: the process or connection can fail after the probe or physical shard commit and before the control-plane metadata commit, because the two writes execute in separate transactions. The formal model explicitly includes this intermediate crash state. | `BaseRepo.run/3`; `PodContentModel.md` storage contract |
| Residual physical rows become authoritative after an interrupted inline-to-physical promotion. | Rejected candidate: inline rows remain authoritative until the control-plane metadata transaction commits. Retrying promotion drops any residual physical shard objects and re-imports the current inline snapshot. | `Promote.if_needed/1`, `Physical.create_table!/3` |
| Whether a partially committed DDL change can serve rows under the older metadata schema. | Rejected candidate: any schema-version mismatch between physical shard state and control-plane metadata denies access until an operator repairs the table; Ankole does not promise automatic inverse-DDL recovery. | `Physical.state/2`, `BaseRepo`, `PodContentModel.md` |
| Whether crashing between shard drop and metadata deletion leaves table cleanup stuck. | Rejected candidate: deletion marks and queues the table first (immediately hiding marked tables), and both physical shard drops and metadata deletion are idempotent so retries complete cleanly once the background cleanup job runs. | `Bases.Delete`, `Pod.Jobs.PurgePage` |

## Delivery intent lifecycle

- **Production module**: `app/control_plane/lib/ankole/conversations/delivery/intent.ex`
- **Model**: `lean/DeliveryIntent.lean`
- **Conformance suite**: `app/control_plane/test/ankole/conversations/delivery/intent_trace_test.exs`

| Surfaced Case | Runtime Behavior | Formal Scope | Upstream Owner |
| --- | --- | --- | --- |
| `requeue` runs on a row whose `possible_duplicate` is true | `Intent`'s `:requeue` action clears `recovery_status` and moves the row to `:pending` while keeping `possible_duplicate` true so the operator-authorized retry carries its `[Possible duplicate]` notice; `:start_attempt` rejects automatic retries on `:failed` rows with `possible_duplicate == true` until `:requeue` moves the row to `:pending`. | `requeue` in `DeliveryIntent.lean` clears `recovery` and preserves `possibleDuplicate`, and `canStart` admits `:pending` rows (including operator-requeued duplicates) while blocking `:failed` rows with `possibleDuplicate = true`. | `Ankole.Conversations.Delivery.Recovery` sets `possible_duplicate: true` and `possible_duplicate_notice` when requeuing an uncertain delivery, and both `Dispatch.dispatchable_intent?/2` and `Intent`'s `:start_attempt` action block unconfirmed `:failed` duplicate-fenced rows. |
| `requeue` runs on a generic intent | The action rejects the update; generic delivery stops instead of retrying. | The model's `requeue` is the durable-reply contract and omits `delivery_class`. | `Delivery.Intent` validates `delivery_class == :durable_ai_reply`; this is a product decision, not an invariant gap. |
| A finalizer records a result for an attempt that recovery already superseded | The dispatch fence compares status, attempt count, and send timestamp under the row lock; the late result becomes a logged no-op. | `finalize` models only the abstract fence. It does not model the row lock, the stale-result log, or the mirror of a successful intent; `recovery_test.exs` exercises the production no-op. | `dispatch.ex` `refetch_claimed_intent/2`; PostgreSQL row locks. |

## Background Agent Job claims

- **Production module**: `app/control_plane/lib/ankole/background_agent_jobs/lifecycle.ex`
- **Model**: `lean/BackgroundAgentJob.lean`
- **Conformance suite**: `app/control_plane/test/ankole/background_agent_jobs/claim_trace_test.exs`

| Surfaced Case | Runtime Behavior | Formal Scope | Upstream Owner |
| --- | --- | --- | --- |
| `worker_report` names `running` for a Job that is not running | With a `turn_ref` for another attempt, `commit_status_after_runtime_prefix_in_tx/7` returns `:background_agent_job_attempt_changed`; with no `turn_ref`, the status machine would accept the transition. | The model covers the claim and slot transitions, not arbitrary status reports. `worker_report` is treated as an upstream-owned transition. | Every Worker report carries a `turn_ref` authorized by `Ankole.AgentWorkers.WorkerRouteAuth`; internal `commit_status` callers pass only terminal statuses. |
| The per-Agent cap is resolved outside the claim transaction | `Admission` reads `max_running` before opening the transaction so the transaction never waits on another connection. | `maxRunning` is a model parameter; the model does not prove that every caller resolves the same value. | `Ankole.BackgroundAgentJobs.Admission` and the AppConfigure reader. |
| A `waiting_on_user` report releases the slot | The status machine allows `running -> waiting_on_user`; `capacity_available_in_tx?/2` counts only `:running`, so the slot is free. The waiting transition additionally requires a lead Turn with a pending `request_user_input`. | The model proves the counter effect (`waiting_releases_slot`), not the Turn-trajectory precondition. | `Turns.ensure_lead_closed_for_current_attempt_in_tx/2`. |

## Session epoch fence and stale refund

- **Production modules**: `app/control_plane/lib/ankole/sessions/{fence,admission,run}.ex`
- **Model**: `lean/SessionEpoch.lean`
- **Conformance suite**: `app/control_plane/test/ankole/sessions/epoch_trace_test.exs`

| Surfaced Case | Runtime Behavior | Formal Scope | Upstream Owner |
| --- | --- | --- | --- |
| A stale Driver refunds an attempt that a newer admission already replaced | `refund_in_tx/2` accepts any run whose epoch is older than the workspace, locks the live Signal, and decrements `attempt_count` (never below `provider_capacity_attempt_count`) without checking which attempt the run owned. | The model states the loose contract directly: `refund_ignores_run_attempt` and `double_refund_credits_twice`. The conformance suite checks the single stale refund, not the split-brain double refund. | The refund is deliberately keyed to the Signal rather than an attempt row. Closing the gap would require passing a run-owned attempt anchor into `refund_in_tx/2` and a conditional update; the exposure is limited to a split-brain takeover and inflates the retry budget by one per duplicate stale writer. **Decision (2026-10-29):** keep this refund contract and the recorded boundary; no attempt token or conditional update is added. |
| A commit from an older epoch reaches a terminal write | `Fence.check_in_tx/2` compares the locked workspace epoch and returns `:stale_driver`; the transaction rolls back. | The model assumes PostgreSQL row locks keep the workspace row stable through commit; it does not model lock scheduling. | `sessions/fence.ex`, `sessions/run.ex` `finalize_in_tx/4`. |
| A shutdown refund applies after a takeover | `:shutdown` requires `workspace.epoch == run.epoch`; `:stale_driver` requires `workspace.epoch > run.epoch`. | `commitAllowed` and `refund` model the two modes only through the epoch comparison. | `Run.refund_in_tx/2` and `Driver` shutdown handling. |

## Page draft reload

- **Production module**: `app/webapps/pod/state/page-draft.ts`
- **Model**: `lean/PageDraft.lean`
- **Conformance suite**: `app/webapps/pod/state/page-draft-async.test.ts`

| Surfaced Case | Runtime Behavior | Formal Scope | Upstream Owner |
| --- | --- | --- | --- |
| `reload()` starts while the draft already differs from `savedXML` | The read captures the dirty draft, and a later resolve applies because the draft did not change during the request. The edit is replaced unless the caller kept a recovery copy. | The model proves that an edit made **after** the request starts blocks the resolve (`resolve_of_edited`). It does not claim that a read started on a dirty draft is safe. | The page UI calls `reload()` only from the conflict-reset path after `keepRecoveryDraft`, or from the explicit “reload document” action, which is a deliberate replacement. |
| A collaboration `changed` callback from a previous Page calls `saved(content, version)` | `PageDraftModel.saved(content, version)` has no source token and would rewrite the current Page's saved baseline and revision. | `stale_save_rewrites_baseline` records the missing guard instead of assuming it. | `PageCollaboration.dispose()` (`libs/ankole-editor/src/editor/page-collaboration.ts`) checks `disposed` in `receive`, `publish`, and `flush()`; React effect cleanup disposes the previous Page's collaboration before the next effect. JavaScript runs those callbacks on one thread, so a callback cannot straddle the dispose. **Decision (2026-10-29):** keep the collaboration owner's dispose boundary; `PageDraftModel` does not gain a source token. |
| A read resolves with the same revision as the current save | The resolve applies and adopts the read's content. | The model's guard is `¬ version < revision`; it assumes the Page revision identifies committed content. | `pages.revision` is the commit version on the Page row; the same revision denotes the same saved document. |

## Retry ladder

- **Production module**: `app/control_plane/lib/ankole/sessions/turn_error_classifier.ex`
- **Model**: `lean/RetryLadder.lean`
- **Conformance suite**: `app/control_plane/test/ankole/sessions/retry_ladder_test.exs`

| Surfaced Case | Runtime Behavior | Formal Scope | Upstream Owner |
| --- | --- | --- | --- |
| `delay_seconds/3` receives a negative or non-integer attempt | A negative integer is clamped to the first rung (`max(attempt - 1, 0)`); a non-integer raises inside the arithmetic. | The model uses `Nat` and proves the clamp, bounds, and saturation. The owning suite drives `-3..10`, `100`, and `1000`. | Callers pass `attempt_count` / `provider_capacity_attempt_count` counters, which PostgreSQL constrains to integers. |
| Lynx translates the function directly | It does not: the body calls `Enum.at/2` and `Integer.pow/2`, which Lynx does not translate, and cutting them off would erase the result under proof. | The contract uses a standalone Lean model plus an exhaustive production check rather than a translated-function theorem. | `TurnErrorClassifier.delay_seconds/3` keeps its idiomatic list ladder and integer exponentiation; production code is not reshaped for the proof. |
