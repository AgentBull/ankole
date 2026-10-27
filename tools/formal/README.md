# Ankole Formal Verification

`tools/formal/` verifies Elixir modules and protocols from `app/control_plane/` with [Lynx](https://github.com/josevalim/lynx) and Lean 4. See [`AGENTS.md`](AGENTS.md) for the traversal and triage workflow, and [`EXPECTED_INCOMPLETENESS.md`](EXPECTED_INCOMPLETENESS.md) for upstream preconditions excluded from production guards.

## Architecture

- `Mix.Tasks.Compile.AnkoleTargets` in `mix.exs` compiles target production modules directly from `app/control_plane/lib/` into `_build/` with `:debug_info`. Source code has one owner in `app/control_plane/lib/`.
- Lynx translates the BEAM Core Erlang bytecode of each target module and law module into Lean 4 definitions.
- Lean 4 checks each `law` theorem in `test/**/*_laws_test.exs`. A `partial_fixpoint` translation can return `exhausted`; it does not prove totality. A conditional theorem proves the stated postcondition when its precondition completes successfully.
- Stateful protocols use the explicit models in `lean/`. The protocol test runner checks their declarations and exports them for independent kernel checks. These models do not prove equivalence with Ash, PostgreSQL, OTP, or a remote worker.

## Prerequisites

- Elixir `~> 1.20` with the same Erlang/OTP runtime as the Control Plane build
- [`elan`](https://github.com/leanprover/elan) with toolchain `leanprover/lean4:v4.35.0` (`lean` and `lake` in `~/.elan/bin` or `PATH`)

## Commands

Compile the normal FOSS test application first. Its BEAM files provide structs
and imports for the target compiler:

```sh
cd app/control_plane
MIX_ENV=test mix compile
```

Run the following commands from `tools/formal/`:

```sh
# Fetch Lynx and build the Lean runtime
mix deps.get

# Run Lean proofs and ExUnit assertions (cached)
mix test

# Force full Lean elaboration from scratch
LYNX_CACHE=0 mix test

# Emit translated .lean files to tmp/ for inspection
LYNX_DEBUG=lean mix test

# Export declarations and replay them through the standalone Lean kernel and axiom checker
LYNX_CACHE=0 LYNX_EXPORT=tmp/export mix test --only laws
lake --dir deps/lynx/Lean check --from-export tmp/export/Ankole.Formal.Pod.PositionLawsTest/laws-Position.between-universal-contracts.ndjson
# Audit every exported suite, including standalone protocol modules.
# Use a fresh export directory for an audit of one test run.
rg --files tmp/export -g '*.ndjson' | while IFS= read -r proof; do
  lake --dir deps/lynx/Lean check --from-export "$proof" || exit 1
done
# On macOS (no Linux bwrap namespace sandbox), add --inadvisably-no-sandbox.
```

## Verified Targets

| Production Module | Law Suite | Verified Contracts |
| --- | --- | --- |
| `Ankole.Pod.Position` | `test/pod/position_laws_test.exs` | Complete input-boundary classification over `nil \| binary()` bounds (`nil`, valid base-62 keys without trailing `'0'`, empty or invalid binaries, unordered bounds) and universal strict `C`-collation ordering (`lower < mid < upper`) with invariant preservation across arbitrary-length keys. |
| `Ankole.Sessions.WorkerAcquisition` | `test/sessions/worker_acquisition_laws_test.exs` | Absorbing `:unavailable` terminal state, `:idle` immunity to late non-demand events, workspace-reply gating to opening Workers only, `since` deadline preservation across retries and phase changes, round-commit state clearing, bounded timer scheduling (`0..60_000` ms), and provider error detail redaction. |
| `Ankole.AgentWorkers.ProviderKind`, `Ankole.AgentWorkers.Decision` | `test/agent_workers/decision_laws_test.exs` | Non-`nil` generation matching for `current_instance?/2`, exact cleanup selection by production `Decision.next/1` for arbitrary fact maps and proper observation lists that require cleanup, and pause-versus-delete idle release selection (`pause_release?/2`). Cleanup selects the second matching instance when several match, or the first nonmatching instance otherwise. |
| `Ankole.Text` | `test/text_laws_test.exs` | Universal UTF-8 scalar-boundary validity (`String.valid?/1`), byte-budget upper bounds (`byte_size(out) <= max_bytes`), prefix/suffix slice preservation, and exact preservation when `byte_size(text) <= max_bytes` across `utf8_prefix/2`, `utf8_suffix/2`, `truncate_utf8/3`, and `truncate_utf8_window/3`. |

The Decision cleanup law calls the production `Decision.next/1` function. Lean
proves that its translated matcher closure and list traversal agree with the
executable specification, then checks the returned `{:delete_object, object}`
action. This law covers cleanup priority and object selection. It does not cover
the lifecycle decisions used when no object needs cleanup. Translation cutoffs
mark those branches and non-list enumeration; a successful proof establishes
that the inputs in this law cannot reach them.


## V2 contracts

The groups below follow the implementation order. The architecture inputs are
`pod_chat_nuphos_implementation_plan.md`, `pod_authz_pg_implementation_spec.md`,
`lark_aligned_authn_technical_plan.md`, `pod_implementation_plan.md`, and
`base_architecture_plan.md` in `/Users/ding/Downloads/v2-arch`. Current production
callers and owning documents determine the executable contract.

| Group | Proof or traversal | Exact scope |
| --- | --- | --- |
| 1. Reply interactions | `test/conversations/interaction_laws_test.exs` | The translated `InteractionState.resolve/3` rejects a resolution when the production reader returns a non-pending state and input normalization succeeds. A BEAM traversal checks all 16 pairs of four valid interaction states for checkpoint merge. Arbitrary checkpoint merge and normalization totality are not Lean-proved. |
| 2. Activity stream | `test/pod/activity_laws_test.exs` | The translated `PodStream.merge_activity/3` rejects active snapshots with an older epoch, rejects older active revisions at the same epoch, and prevents an active snapshot from reopening a settled epoch. Publisher identity and diagnostic recovery have production protocol tests. |
| 3. Formula | `test/pod/formula_laws_test.exs` | A translated field-reference node replaces its ID with the mapped ID for arbitrary old and new terms. All 512 three-node directed graphs are executed through production validation and compared with an independent transitive closure. Acyclic graphs must preserve every field, order dependencies before consumers, and preserve ordering under an injective rename. This finite traversal does not prove DFS correctness for arbitrary graph size or recursive remapping for every AST. |
| 4. File paths and actions | `test/files/path_laws_test.exs`, `test/pod/file_actions_laws_test.exs` | Successful production path validation implies valid UTF-8 and a byte length from 1 to 1024. Production prefix classification requires view for public assets and edit for private source paths. Segment validation and fixed configuration files have executable boundary checks. The byte-budget theorem does not prove every valid path is accepted. |
| 5. ACL graph and moves | `lean/AccessGraph.lean` | Seed reachability, denial without seeds, monotonic grants, contraction of a transparent single-parent node, Human/Agent intersection, and preservation for every actor under equal symbolic policies. |
| 6. Human access and OTP | `lean/HumanAccess.lean` | Offboarding survives suspension in the disabled cycle; restoration ends that cycle; offboarding releases credentials even for a disabled Human; an old or equal-time challenge fails the release watermark. OTP consumption is absorbing and an arbitrary event trace accepts at most once. |
| 7. Attempt authority | `lean/AttemptAuthority.lean` | A write needs the current Job, Run, assigned Agent, attempt ID, and Human version. A replaced attempt, revoked Human, or inactive Job cannot change durable state. |
| 8. Applet lifecycle | `lean/AppletLifecycle.lean` | Arbitrary modeled traces start user execution at most once; admission retry shares one deadline; a terminal result absorbs late frames and cleanup failure; cancellation preserves writes that already committed. |
| 9. Base recovery | `lean/BaseRecovery.lean` | A promotion interrupted before the metadata commit leaves inline rows authoritative; a retry replaces residual shard data; completed promotion preserves rows. A partial DDL commit fails the version check. Marked deletion is hidden, shard cleanup and metadata removal are idempotent, and metadata removal requires completed shard cleanup. |

### Protocol correspondence and assumptions

The five protocol models prove implications of their transitions. They do not
translate the stateful production modules. The following source review and real
adapter tests support the correspondence; they are not universal equivalence
proofs.

| Model | Production transition and required boundary | Production suite under `app/control_plane/test/` |
| --- | --- | --- |
| `AccessGraph` | `pod/access/graph.ex` seeds and recursive dependency edges; `pod/access.ex` symbolic policy comparison. A transparent anchor has no local seed and exactly one inherited dependency for the given scope and action. Visibility filtering, condition evaluation, tenant selection, and graph extraction remain SQL/application obligations. | `ankole/pod/anchor_property_test.exs`, `ankole/pod/move_permissions_test.exs` |
| `HumanAccess` | `principals/human_access.ex` checks offboard restrictions against their `cleared_at` and the last restore, not the latest reason. `principals/site_credentials.ex` selects the latest release for the claimed credential. `authn/strategies/otp/actions.ex` locks and consumes the challenge in a transaction separate from completion. The model abstracts one credential with a release watermark and one challenge row; a successful status change advances its access version. | `ankole/principals/offboarding_credentials_test.exs`, `ankole/authn/otp_test.exs` |
| `AttemptAuthority` | `automation_jobs/attempt_access.ex` and `pod/access.ex` recheck authority inside the write transaction. Human, Job, and Run locks keep the checked facts stable through commit. `WorkAccess.classify_in_tx/5` cannot reassign an active human-authorized Job; the review path rejects active attempts until authorization is valid. The model assumes these lock and action contracts. | `ankole/pod/automation_attempt_test.exs` (real RPC codec and Pod writes) |
| `AppletLifecycle` | `function_runtime/applet_client.ex` retries only admission connection failures or 503 responses, once, before `start`; all admission work uses one absolute deadline. Its frame reducer keeps the first terminal outcome. `pod/applets/invocation.ex` owns capability tasks and cancellation. The model covers admission/start/result ordering, not mailbox fairness, remote task termination, or rollback of capabilities. | `ankole/function_runtime/applet_client_test.exs` (real local HTTP and WebSocket) |
| `BaseRecovery` | `pod/bases/promote.ex`, `pod/bases/physical.ex`, `pod/base_repo.ex`, and `pod/bases/delete.ex`. Metadata locks serialize each table; each local transaction is atomic; promotion copies the current authoritative rows; access checks versions and deletion state. The model abstracts one table's committed snapshots. It does not prove PostgreSQL, multi-table links, general distributed atomicity, or eventual cleanup without a running job executor. | `ankole/pod/base_storage_test.exs` (real control-plane and Base shard databases) |

### Runtime support

`patches/lynx-map-iterator.patch` supplies unordered map iteration and the
empty-list `lists:keyfind/3` case used by default keyword options. The dependency
compile command applies the patch reproducibly. `RuntimeSupport.lean` proves
that an iterator emits every visible binding once in `Term.mapEntries` order.
The map order stays unspecified. Nonempty keyword searches, unsupported map
iterators, and translation cutoffs cannot return success in a proof.

This extension is part of the trusted Erlang runtime model. Its kernel proof
checks internal consistency, not equivalence to the Erlang VM. The proof scopes
above do not use an ordered iterator or a nonempty keyword search. Cutoffs for
regex, empty-pattern splitting, ranges, and compiled-pattern warnings exclude
branches that these production calls do not use.

The custom compiler accepts `mix compile --force`, recompiles target files from
production source, and removes target outputs when compilation fails. It never
copies production logic into a formal-only Elixir module.
