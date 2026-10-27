# Ankole Formal Verification

`tools/formal/` verifies Elixir modules and stateful protocols from `app/control_plane/` using [Lynx](https://github.com/josevalim/lynx) and Lean 4. See [`AGENTS.md`](AGENTS.md) for the traversal and triage workflow, and [`EXPECTED_INCOMPLETENESS.md`](EXPECTED_INCOMPLETENESS.md) for upstream preconditions that production code relies on rather than duplicating as defensive guards.

## Architecture

- `Mix.Tasks.Compile.AnkoleTargets` in `mix.exs` compiles target production modules directly from `app/control_plane/lib/` into `_build/` with `:debug_info`, so `app/control_plane/lib/` remains the single owner of production source code.
- Lynx translates the BEAM Core Erlang bytecode of each target module and law module into Lean 4 definitions.
- Lean 4 checks every `law` theorem in `test/**/*_laws_test.exs`. Because recursive functions translated via `partial_fixpoint` can evaluate to `exhausted`, a Lean proof establishes partial correctness rather than termination: whenever a law's precondition completes successfully, its postcondition holds.
- Stateful protocols are modeled explicitly in `lean/`. The protocol test runner typechecks those Lean declarations and exports them for standalone kernel verification; these models verify protocol transitions rather than proving end-to-end equivalence with Ash, PostgreSQL, OTP, or remote Workers.

## Prerequisites

- Elixir `~> 1.20` running on the same Erlang/OTP version as the Control Plane build
- [`elan`](https://github.com/leanprover/elan) with toolchain `leanprover/lean4:v4.35.0` (`lean` and `lake` on `PATH` or in `~/.elan/bin`)

## Commands

Compile the open-source Control Plane test application first so its BEAM files
provide structs and macro imports to the target compiler:

```sh
cd app/control_plane
MIX_ENV=test mix compile
```

Then run the verification commands from `tools/formal/`:

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
| `Ankole.Pod.Position` | `test/pod/position_laws_test.exs` | Complete input-boundary classification over `nil \| binary()` bounds (`nil`, valid base-62 keys without trailing `'0'`, empty or invalid binaries, and unordered bounds) together with universal strict `C`-collation ordering (`lower < mid < upper`) and invariant preservation across keys of arbitrary length. |
| `Ankole.Sessions.WorkerAcquisition` | `test/sessions/worker_acquisition_laws_test.exs` | Absorbing `:unavailable` terminal state, `:idle` immunity to late non-demand events, gating of workspace replies to opening Workers only, preservation of the `since` deadline across retries and phase transitions, state clearing on round commit, bounded timer scheduling (`0..60_000` ms), and redaction of provider error details. |
| `Ankole.AgentWorkers.ProviderKind`, `Ankole.AgentWorkers.Decision` | `test/agent_workers/decision_laws_test.exs` | Non-`nil` generation matching in `current_instance?/2`, exact cleanup selection by production `Decision.next/1` across arbitrary fact maps and proper observation lists requiring cleanup (selecting the second matching instance when multiple instances match, or the first non-matching instance otherwise), and selecting pause versus delete on idle release (`pause_release?/2`). |
| `Ankole.Text` | `test/text_laws_test.exs` | Valid UTF-8 scalar boundaries (`String.valid?/1`), byte-budget upper bounds (`byte_size(out) <= max_bytes`), prefix/suffix slice preservation, and exact input preservation whenever `byte_size(text) <= max_bytes` across `utf8_prefix/2`, `utf8_suffix/2`, `truncate_utf8/3`, and `truncate_utf8_window/3`. |

The Decision cleanup law invokes the translated production `Decision.next/1`
function directly: Lean proves that its translated matcher closure and list
traversal agree with the executable specification and return the expected
`{:delete_object, object}` action. This law covers cleanup priority and object
selection; lifecycle branches taken when no object requires cleanup—along with
non-list enumeration—are replaced by translation cutoffs, so a passing proof
demonstrates that inputs satisfying the cleanup precondition never reach those
cutoffs.

## V2 contracts

The groups below follow the implementation sequence derived from the
architecture specifications (`pod_chat_nuphos_implementation_plan.md`,
`pod_authz_pg_implementation_spec.md`, `lark_aligned_authn_technical_plan.md`,
`pod_implementation_plan.md`, and `base_architecture_plan.md` in
`/Users/ding/Downloads/v2-arch`), with current production callers and owning
design documents defining the authoritative executable contract.

| Group | Proof or traversal | Exact scope |
| --- | --- | --- |
| 1. Reply interactions | `test/conversations/interaction_laws_test.exs` | Proves that translated `InteractionState.resolve/3` rejects resolution whenever the production reader returns a non-pending state and input normalization succeeds, and uses an exhaustive BEAM traversal across all 16 pairs of the four valid interaction states to verify checkpoint merging. Arbitrary-map checkpoint merging and normalization totality are not Lean-proved. |
| 2. Activity stream | `test/pod/activity_laws_test.exs` | Proves that translated `PodStream.merge_activity/3` rejects active snapshots from older epochs, rejects older active revisions within the same epoch, and prevents active snapshots from reopening a settled epoch. Publisher identity and diagnostic recovery are covered by production protocol tests. |
| 3. Formula | `test/pod/formula_laws_test.exs` | Proves that a translated field-reference node substitutes its mapped ID for arbitrary old and new terms, and runs all 512 three-node directed graphs through production validation against an independent transitive closure—verifying that acyclic graphs preserve all fields, order dependencies before consumers, and preserve order under injective renames. This bounded traversal does not prove DFS correctness for arbitrary graph sizes or recursive remapping over arbitrary ASTs. |
| 4. File paths and actions | `test/files/path_laws_test.exs`, `test/pod/file_actions_laws_test.exs` | Proves that successful production path validation guarantees valid UTF-8 with byte length in `1..1024`, and that production prefix classification requires `view` for public assets and `edit` for private source paths. Segment validation and fixed configuration files are covered by executable boundary checks; the byte-budget theorem does not prove that every valid path is accepted. |
| 5. ACL graph and moves | `lean/AccessGraph.lean` | Proves seed reachability, denial without seeds, monotonic grants, contraction of transparent single-parent anchors, Human/Agent permission intersection, and permission preservation across all actors when symbolic policies match. |
| 6. Human access and OTP | `lean/HumanAccess.lean` | Proves that offboarding persists across subsequent suspensions within a disabled cycle, restoration ends that cycle, offboarding releases credentials even for an already-disabled Human, challenges started before or at the release timestamp fail the watermark check, and OTP consumption is absorbing so any trace accepts a challenge at most once. |
| 7. Attempt authority | `lean/AttemptAuthority.lean` | Proves that committing a write requires the current Job, Run, assigned Agent, attempt ID, and Human access version, preventing replaced attempts, revoked Humans, or inactive Jobs from mutating durable state. |
| 8. Applet lifecycle | `lean/AppletLifecycle.lean` | Proves across arbitrary modeled traces that user execution starts at most once, admission retries share a single absolute deadline, the first terminal outcome absorbs late frames and cleanup failures, and cancellation leaves already-committed capability writes intact. |
| 9. Base recovery | `lean/BaseRecovery.lean` | Proves that interrupting promotion before metadata commit leaves inline rows authoritative, retrying promotion replaces residual shard data, completed promotion preserves rows, partial DDL commits fail version checks, marked deletions hide tables immediately, shard cleanup and metadata deletion are idempotent, and metadata deletion waits for completed shard cleanup. |

### Protocol correspondence and assumptions

The five Lean protocol models prove invariants over explicit state-transition
systems rather than translating stateful Elixir processes directly. We audit
alignment between each model and production through code review and integration
suites against real adapters (rather than universal refinement proofs):

| Model | Production transition and required boundary | Production suite under `app/control_plane/test/` |
| --- | --- | --- |
| `AccessGraph` | `pod/access/graph.ex` seeds and recursive dependency edges; `pod/access.ex` symbolic policy comparison. Assumes transparent anchors have no local seed and a single inherited dependency for the given scope and action; visibility filtering, condition evaluation, tenant scoping, and SQL graph extraction remain obligations of the application and database layers. | `ankole/pod/anchor_property_test.exs`, `ankole/pod/move_permissions_test.exs` |
| `HumanAccess` | `principals/human_access.ex` evaluates offboard restrictions against `cleared_at` and the latest restore rather than the latest status reason; `principals/site_credentials.ex` reads the latest credential release; `authn/strategies/otp/actions.ex` locks and consumes the challenge row in a separate transaction prior to completion. Abstracts a single credential watermark and challenge row where each status transition increments the Human's access version. | `ankole/principals/offboarding_credentials_test.exs`, `ankole/authn/otp_test.exs` |
| `AttemptAuthority` | `automation_jobs/attempt_access.ex` and `pod/access.ex` re-verify authority inside the write transaction while Human, Job, and Run locks hold those rows stable until commit. `WorkAccess.classify_in_tx/5` prevents reassigning an active human-authorized Job, and the review path rejects active attempts until authorization is valid. Assumes these row-lock and action invariants. | `ankole/pod/automation_attempt_test.exs` (real RPC codec and Pod writes) |
| `AppletLifecycle` | `function_runtime/applet_client.ex` retries at most once on admission connection failure or HTTP `503` before `start`, sharing one absolute deadline across all admission steps, while its frame reducer retains the first terminal outcome; `pod/applets/invocation.ex` supervises capability tasks and cancellation. Models admission/start/result ordering without modeling BEAM mailbox fairness, remote process termination, or capability rollback. | `ankole/function_runtime/applet_client_test.exs` (real local HTTP and WebSocket) |
| `BaseRecovery` | `pod/bases/promote.ex`, `pod/bases/physical.ex`, `pod/base_repo.ex`, and `pod/bases/delete.ex`. Metadata row locks serialize per-table operations, local transactions commit atomically, promotion copies authoritative inline rows, and reads verify schema versions and deletion markers. Abstracts committed snapshots of a single table without modeling PostgreSQL internals, cross-table links, distributed transactions, or background job scheduling. | `ankole/pod/base_storage_test.exs` (real control-plane and Base shard databases) |

### Runtime support

`patches/lynx-map-iterator.patch` adds unordered map iteration and the
empty-list `lists:keyfind/3` clause required by default keyword options, applied
reproducibly during dependency compilation. `RuntimeSupport.lean` proves that a
map iterator yields each visible entry once in `Term.mapEntries` order while
leaving map ordering unspecified. Nonempty keyword lookups, unsupported map
iterators, and translation cutoffs evaluate to non-success states so proofs
cannot silently pass through unmodeled branches.

This patch extends the trusted Erlang runtime model in Lean; its kernel proof
establishes internal consistency rather than equivalence with the BEAM VM. None
of the verified scopes above depend on ordered map iterators or nonempty keyword
lookups, and translation cutoffs for regular expressions, empty-pattern splits,
ranges, and compiled-pattern warnings prune branches unused by the verified
production callers.

Finally, `Mix.Tasks.Compile.AnkoleTargets` honors `mix compile --force`,
recompiles targets directly from `app/control_plane/lib/`, cleans stale outputs
on compiler failure, and never duplicates production code into formal-only
Elixir modules.
