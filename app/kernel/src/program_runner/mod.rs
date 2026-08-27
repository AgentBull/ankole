//! One-shot deterministic program execution for AIGateway PTC.
//!
//! AIGateway self-implements the official OpenAI Programmatic Tool Calling
//! semantics. Pause and resume use replay with memoization: every run starts a
//! fresh bare isolate, replays the program from the top, answers memoized tool
//! calls from the recorded transcript, and stalls when unanswered client-owned
//! calls remain. The stall set becomes the next `function_call` batch, so one
//! run never outlives one gateway request and no isolate survives a pause.
//!
//! The runtime is a bare `deno_core::JsRuntime`: no Node, no network, no
//! filesystem, no timers. The only capabilities are per-tool async bindings,
//! `text(...)` / `image(...)` output, and deterministic `Math.random` /
//! `Date.now` shims so replays reproduce the recorded call sequence.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::pin::Pin;
use std::rc::Rc;
use std::sync::atomic::{AtomicU8, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::task::{Context, Poll};
use std::time::Duration;

use deno_core::{JsRuntime, OpState, PollEventLoopOptions, RuntimeOptions, op2};
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;

/// Limits the wall-clock time of one replay attempt.
const DEFAULT_TIMEOUT_MS: u64 = 30_000;
/// Keeps one V8 isolate inside the Worker memory budget.
const DEFAULT_HEAP_LIMIT_BYTES: usize = 256 * 1024 * 1024;
/// Prevents one model-produced program from dominating compile work.
const DEFAULT_MAX_PROGRAM_BYTES: usize = 256 * 1024;
/// Bounds all output that one program can return to AIGateway.
const DEFAULT_MAX_OUTPUT_BYTES: usize = 1024 * 1024;
/// Keeps one runtime failure safe to store and send.
const DEFAULT_MAX_ERROR_BYTES: usize = 16 * 1024;
/// Bounds one text output before it enters the shared output budget.
const DEFAULT_MAX_TEXT_BYTES: usize = 64 * 1024;
/// Bounds one image reference before it enters the shared output budget.
const DEFAULT_MAX_IMAGE_BYTES: usize = 16 * 1024;
/// Bounds the first tool-call batch that can pause a program.
const DEFAULT_MAX_PENDING_CALLS: usize = 64;
/// Bounds all arguments retained for one unanswered tool-call batch.
const DEFAULT_MAX_PENDING_BYTES: usize = 1024 * 1024;
/// Prevents one call from consuming the complete pending-call budget.
const DEFAULT_MAX_PENDING_ARGUMENT_BYTES: usize = 256 * 1024;
/// Bounds the replay steps that one request can supply.
const DEFAULT_MAX_MEMO_ENTRIES: usize = 1024;
/// Bounds the retained replay state that enters a fresh isolate.
const DEFAULT_MAX_MEMO_BYTES: usize = 8 * 1024 * 1024;
/// Bounds the bindings that the generated JavaScript prelude installs.
const DEFAULT_MAX_TOOLS: usize = 128;
/// Keeps one generated JavaScript binding name bounded.
const DEFAULT_MAX_TOOL_NAME_BYTES: usize = 256;
/// Bounds all names copied into the generated JavaScript prelude.
const DEFAULT_MAX_TOOL_NAMES_BYTES: usize = 16 * 1024;
/// Rejects an oversized request before it creates runner state.
const MAX_RUN_REQUEST_BYTES: usize = 16 * 1024 * 1024;
/// Keeps process-local cancellation registry keys bounded.
const MAX_RUN_ID_BYTES: usize = 128;
/// Bounds the number of output values even when each value is small.
const MAX_OUTPUT_PARTS: usize = 256;
/// Marks an isolate that can still accept one termination reason.
const EXECUTION_RUNNING: u8 = 0;
/// Records that the watchdog ended the run.
const TERMINATION_TIMEOUT: u8 = 1;
/// Records that the V8 heap limit ended the run.
const TERMINATION_HEAP: u8 = 2;
/// Records that the caller ended the run.
const TERMINATION_CANCELLED: u8 = 3;
/// Prevents termination while the host reads the final state.
const EXECUTION_FINISHING: u8 = 4;
/// Marks a run whose final state is no longer mutable.
const EXECUTION_DONE: u8 = 5;

#[cfg(not(test))]
/// Bounds simultaneous V8 heap reservations inside one Worker.
const MAX_CONCURRENT_RUNS: usize = 4;
#[cfg(test)]
/// Lets concurrency tests exceed the production admission limit.
const MAX_CONCURRENT_RUNS: usize = 64;

/// Applies the process-wide V8 admission limit before an isolate is created.
static ACTIVE_RUNS: AtomicUsize = AtomicUsize::new(0);
/// Lets cancellation find only the isolate that owns the current run ID.
static RUN_REGISTRY: OnceLock<Mutex<HashMap<String, Arc<RunControl>>>> = OnceLock::new();

/// One cancellation authority for the V8 isolate that is currently running.
/// Watchdog, heap pressure, and caller cancellation all race through the same
/// execution phase, so V8 is terminated at most once and never after the host
/// starts finishing.
struct RunControl {
    execution_phase: AtomicU8,
    isolate: Mutex<Option<deno_core::v8::IsolateHandle>>,
}

impl RunControl {
    fn new() -> Self {
        Self {
            execution_phase: AtomicU8::new(EXECUTION_RUNNING),
            isolate: Mutex::new(None),
        }
    }

    fn install_isolate(&self, handle: deno_core::v8::IsolateHandle) {
        let mut isolate = self
            .isolate
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        *isolate = Some(handle.clone());

        if self.execution_phase.load(Ordering::SeqCst) == TERMINATION_CANCELLED {
            handle.terminate_execution();
        }
    }

    fn clear_isolate(&self) {
        self.isolate
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .take();
    }

    fn terminate(&self, reason: u8) {
        if self
            .execution_phase
            .compare_exchange(
                EXECUTION_RUNNING,
                reason,
                Ordering::SeqCst,
                Ordering::SeqCst,
            )
            .is_ok()
            && let Some(handle) = self
                .isolate
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .as_ref()
        {
            handle.terminate_execution();
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RunRequest {
    pub program: String,
    #[serde(default)]
    pub tools: Vec<ToolDefinition>,
    #[serde(default)]
    pub memo: Vec<MemoEntry>,
    #[serde(default)]
    pub timeout_ms: Option<u64>,
    #[serde(default)]
    pub heap_limit_bytes: Option<usize>,
    #[serde(default)]
    pub max_program_bytes: Option<usize>,
    #[serde(default)]
    pub max_output_bytes: Option<usize>,
    #[serde(default)]
    pub max_pending_calls: Option<usize>,
    #[serde(default)]
    pub max_pending_bytes: Option<usize>,
    #[serde(default)]
    pub max_memo_entries: Option<usize>,
    #[serde(default)]
    pub max_memo_bytes: Option<usize>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ToolDefinition {
    pub namespace: Option<String>,
    pub name: String,
    pub global_name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct ToolIdentity {
    namespace: Option<String>,
    name: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct MemoEntry {
    #[serde(default)]
    pub namespace: Option<String>,
    pub name: String,
    pub arguments: JsonValue,
    pub output: JsonValue,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct PendingCall {
    pub namespace: Option<String>,
    pub name: String,
    pub arguments: JsonValue,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct OutputPart {
    pub kind: String,
    pub value: String,
}

#[derive(Debug, Serialize)]
pub struct RunOutcome {
    pub status: String,
    pub output: Vec<OutputPart>,
    pub pending_calls: Vec<PendingCall>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
}

#[derive(Clone)]
struct ProgramFailure {
    code: String,
    message: String,
}

enum ProgramStatus {
    Running,
    Completed,
    Failed(String),
}

struct ProgramState {
    allowed_tools: HashMap<String, ToolIdentity>,
    memo: Vec<MemoEntry>,
    memo_cursor: usize,
    pending_calls: Vec<PendingCall>,
    pending_bytes: usize,
    output: Vec<OutputPart>,
    output_bytes: usize,
    activity: u64,
    divergence: Option<String>,
    failure: Option<ProgramFailure>,
    status: ProgramStatus,
    max_output_bytes: usize,
    max_pending_calls: usize,
    max_pending_bytes: usize,
    max_pending_argument_bytes: usize,
}

impl ProgramState {
    fn new(request: &mut RunRequest, allowed_tools: HashMap<String, ToolIdentity>) -> Self {
        Self {
            allowed_tools,
            memo: std::mem::take(&mut request.memo),
            memo_cursor: 0,
            pending_calls: Vec::new(),
            pending_bytes: 0,
            output: Vec::new(),
            output_bytes: 0,
            activity: 0,
            divergence: None,
            failure: None,
            status: ProgramStatus::Running,
            max_output_bytes: capped(request.max_output_bytes, DEFAULT_MAX_OUTPUT_BYTES),
            max_pending_calls: capped(request.max_pending_calls, DEFAULT_MAX_PENDING_CALLS),
            max_pending_bytes: capped(request.max_pending_bytes, DEFAULT_MAX_PENDING_BYTES),
            max_pending_argument_bytes: DEFAULT_MAX_PENDING_ARGUMENT_BYTES,
        }
    }

    fn fail(&mut self, code: &str, message: String) {
        if self.failure.is_none() {
            self.failure = Some(ProgramFailure {
                code: code.to_string(),
                message: bounded_message(&message),
            });
        }
    }

    fn push_output(&mut self, kind: &str, value: String) -> bool {
        let part_limit = if kind == "image" {
            DEFAULT_MAX_IMAGE_BYTES
        } else {
            DEFAULT_MAX_TEXT_BYTES
        };
        let next_bytes = self.output_bytes.saturating_add(value.len());

        if value.len() > part_limit
            || self.output.len() >= MAX_OUTPUT_PARTS
            || next_bytes > self.max_output_bytes
        {
            self.fail(
                "program_output_limit_exceeded",
                format!(
                    "program output exceeded the per-part, {}-part, or {}-byte limit",
                    MAX_OUTPUT_PARTS, self.max_output_bytes,
                ),
            );
            return false;
        }

        self.output_bytes = next_bytes;
        self.output.push(OutputPart {
            kind: kind.to_string(),
            value,
        });
        true
    }
}

/// A future that keeps one unanswered tool call pending forever. The stalled
/// event loop is the pause signal.
struct EternalPend;

impl Future for EternalPend {
    type Output = JsonValue;

    fn poll(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Self::Output> {
        Poll::Pending
    }
}

// Every resolved op result is host-tagged before JavaScript unwraps it. A tool
// output can therefore contain any object keys without impersonating a host
// replay error.
#[op2]
#[serde]
async fn op_ankole_tool_call(
    state: Rc<RefCell<OpState>>,
    #[string] name: String,
    #[serde] arguments: JsonValue,
) -> JsonValue {
    enum Reply {
        Memo(JsonValue),
        Diverged(String),
        Pend,
    }

    let reply = {
        let mut op_state = state.borrow_mut();
        let program = op_state.borrow_mut::<ProgramState>();
        program.activity += 1;

        let Some(identity) = program.allowed_tools.get(&name).cloned() else {
            let message = format!("program tool is not enabled: {name}");
            program.fail("program_tool_not_allowed", message.clone());
            return serde_json::json!({
                "__ankole_reply": "error",
                "error": message,
            });
        };

        if program.memo_cursor < program.memo.len() {
            let entry = &program.memo[program.memo_cursor];

            if entry.namespace == identity.namespace
                && entry.name == identity.name
                && entry.arguments == arguments
            {
                let output = entry.output.clone();
                program.memo_cursor += 1;
                Reply::Memo(output)
            } else {
                let message = format!(
                    "program replay diverged: expected {}({}), got {}({})",
                    qualified_name(entry.namespace.as_deref(), &entry.name),
                    entry.arguments,
                    qualified_name(identity.namespace.as_deref(), &identity.name),
                    arguments
                );
                program.divergence = Some(message.clone());
                Reply::Diverged(message)
            }
        } else {
            let argument_bytes =
                serde_json::to_vec(&arguments).map_or(usize::MAX, |value| value.len());
            let next_pending_bytes = program.pending_bytes.saturating_add(argument_bytes);

            if argument_bytes > program.max_pending_argument_bytes
                || program.pending_calls.len() >= program.max_pending_calls
                || next_pending_bytes > program.max_pending_bytes
            {
                let message = format!(
                    "program pending calls exceeded the per-argument, {}-call, or {}-byte limit",
                    program.max_pending_calls, program.max_pending_bytes,
                );
                program.fail("program_pending_limit_exceeded", message.clone());
                Reply::Diverged(message)
            } else {
                program.pending_bytes = next_pending_bytes;
                program.pending_calls.push(PendingCall {
                    namespace: identity.namespace,
                    name: identity.name,
                    arguments,
                });
                Reply::Pend
            }
        }
    };

    match reply {
        Reply::Memo(output) => serde_json::json!({
            "__ankole_reply": "memo",
            "value": output,
        }),
        Reply::Diverged(message) => serde_json::json!({
            "__ankole_reply": "error",
            "error": message,
        }),
        Reply::Pend => EternalPend.await,
    }
}

#[op2(fast)]
fn op_ankole_text(state: &mut OpState, #[string] text: String) -> bool {
    let program = state.borrow_mut::<ProgramState>();
    program.activity += 1;
    program.push_output("text", text)
}

#[op2(fast)]
fn op_ankole_image(state: &mut OpState, #[string] url: String) -> bool {
    let program = state.borrow_mut::<ProgramState>();
    program.activity += 1;
    program.push_output("image", url)
}

deno_core::extension!(
    ankole_program,
    ops = [op_ankole_tool_call, op_ankole_text, op_ankole_image],
);

/// Runs one program to completion or to its first unanswered tool-call batch.
pub fn run(request: RunRequest) -> RunOutcome {
    let Some(_permit) = RunPermit::acquire() else {
        return failed(
            "program_runtime_busy",
            "program runtime concurrency limit reached",
        );
    };

    guarded_execute(request, Arc::new(RunControl::new()))
}

/// Registers and runs one cancellable native execution.
pub fn run_registered(run_id: &str, request: RunRequest) -> RunOutcome {
    let Some(_permit) = RunPermit::acquire() else {
        return failed(
            "program_runtime_busy",
            "program runtime concurrency limit reached",
        );
    };

    let running = match RunningRun::begin(run_id) {
        Ok(running) => running,
        Err(failure) => return failed(&failure.code, &failure.message),
    };

    guarded_execute(request, Arc::clone(&running.control))
}

fn guarded_execute(request: RunRequest, control: Arc<RunControl>) -> RunOutcome {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| execute(request, control))) {
        Ok(outcome) => outcome,
        Err(_panic) => failed("program_runtime_panicked", "program runtime panicked"),
    }
}

fn failed(code: &str, message: &str) -> RunOutcome {
    RunOutcome {
        status: "failed".to_string(),
        output: Vec::new(),
        pending_calls: Vec::new(),
        error: Some(bounded_message(message)),
        error_code: Some(code.to_string()),
    }
}

fn execute(mut request: RunRequest, control: Arc<RunControl>) -> RunOutcome {
    let allowed_tools = match validate_request(&request) {
        Ok(allowed_tools) => allowed_tools,
        Err(failure) => return failed(&failure.code, &failure.message),
    };

    if let Some(outcome) = termination_outcome(&control.execution_phase) {
        return outcome;
    }

    let timeout = Duration::from_millis(
        request
            .timeout_ms
            .unwrap_or(DEFAULT_TIMEOUT_MS)
            .min(DEFAULT_TIMEOUT_MS),
    );
    let heap_limit = request
        .heap_limit_bytes
        .filter(|limit| *limit > 0)
        .unwrap_or(DEFAULT_HEAP_LIMIT_BYTES)
        .min(DEFAULT_HEAP_LIMIT_BYTES);

    let tokio_runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            return failed(
                "program_runtime_unavailable",
                &format!("tokio runtime unavailable: {error}"),
            );
        }
    };
    let _runtime_guard = tokio_runtime.enter();

    let mut js_runtime = JsRuntime::new(RuntimeOptions {
        extensions: vec![ankole_program::init()],
        create_params: Some(deno_core::v8::CreateParams::default().heap_limits(0, heap_limit)),
        ..Default::default()
    });

    let isolate_handle = js_runtime.v8_isolate().thread_safe_handle();
    control.install_isolate(isolate_handle);

    // Only a running isolate may be terminated. Once the host claims the
    // finishing phase, watchdog and heap callbacks can no longer race a
    // terminal read with a fresh V8 termination.
    let heap_control = Arc::clone(&control);
    js_runtime.add_near_heap_limit_callback(move |current, _initial| {
        heap_control.terminate(TERMINATION_HEAP);
        current * 2
    });

    let program_state = ProgramState::new(&mut request, allowed_tools);
    js_runtime.op_state().borrow_mut().put(program_state);

    let watchdog_control = Arc::clone(&control);
    let (cancel_watchdog, watchdog_cancelled) = std::sync::mpsc::channel::<()>();
    let watchdog = std::thread::spawn(move || {
        if watchdog_cancelled.recv_timeout(timeout).is_err() {
            watchdog_control.terminate(TERMINATION_TIMEOUT);
        }
    });

    let outcome = tokio_runtime.block_on(drive(
        &mut js_runtime,
        &request.program,
        &request.tools,
        &control.execution_phase,
    ));

    let _ = cancel_watchdog.send(());
    let _ = watchdog.join();
    control.clear_isolate();
    let _ = control.execution_phase.compare_exchange(
        EXECUTION_FINISHING,
        EXECUTION_DONE,
        Ordering::SeqCst,
        Ordering::SeqCst,
    );

    outcome
}

async fn drive(
    js_runtime: &mut JsRuntime,
    program: &str,
    tools: &[ToolDefinition],
    execution_phase: &AtomicU8,
) -> RunOutcome {
    if let Err(error) = js_runtime.execute_script("ankole:prelude", prelude(tools)) {
        return claim_failure(
            execution_phase,
            "program_prelude_failed",
            &format!("program prelude failed: {error}"),
        );
    }

    let wrapped = format!("(async () => {{\n{program}\n}})()");

    let promise = match js_runtime.execute_script("ankole:program", wrapped) {
        Ok(promise) => promise,
        Err(error) => {
            return claim_failure(
                execution_phase,
                "program_start_failed",
                &format!("program rejected before start: {error}"),
            );
        }
    };

    // `JsRuntime::resolve` installs a V8 promise hook without consulting the
    // user-mutable `Promise.prototype.then`. Completion is therefore a host
    // fact: model code cannot invoke a completion op or monkey-patch the
    // wrapper into settling early.
    let mut program_resolution = Box::pin(js_runtime.resolve(promise));

    // The only async ops are tool calls: memoized calls resolve within the
    // tick and unanswered calls pend forever. A Pending event loop with no new
    // op activity between two polls therefore means the program stalled on its
    // pending batch.
    let mut last_activity = activity(js_runtime);
    let mut event_loop_idle_once = false;

    loop {
        let (resolution, poll_result) = futures_util::future::poll_fn(|cx| {
            Poll::Ready((
                program_resolution.as_mut().poll(cx),
                js_runtime.poll_event_loop(cx, PollEventLoopOptions::default()),
            ))
        })
        .await;

        if let Some(outcome) = termination_outcome(execution_phase) {
            return outcome;
        }

        match resolution {
            Poll::Ready(Ok(_value)) => {
                set_program_status(js_runtime, ProgramStatus::Completed);
                return safe_finish(js_runtime, None, execution_phase);
            }
            Poll::Ready(Err(error)) => {
                set_program_status(
                    js_runtime,
                    ProgramStatus::Failed(bounded_message(&error.to_string())),
                );
                return safe_finish(js_runtime, None, execution_phase);
            }
            Poll::Pending => {}
        }

        match poll_result {
            Poll::Ready(Ok(())) => {
                // Promise hooks can resolve one host poll after the event loop
                // first reports idle. Give the native resolver that turn, but
                // do not spin forever for a promise with no operations.
                if event_loop_idle_once {
                    return safe_finish(js_runtime, None, execution_phase);
                }

                event_loop_idle_once = true;
                tokio::task::yield_now().await;
            }
            Poll::Ready(Err(error)) => {
                return safe_finish(
                    js_runtime,
                    Some(ProgramFailure {
                        code: "program_event_loop_failed".to_string(),
                        message: error.to_string(),
                    }),
                    execution_phase,
                );
            }

            Poll::Pending => {
                event_loop_idle_once = false;

                if has_host_failure(js_runtime) {
                    return safe_finish(js_runtime, None, execution_phase);
                }

                let current_activity = activity(js_runtime);

                if current_activity == last_activity && has_pending_calls(js_runtime) {
                    return safe_finish(js_runtime, None, execution_phase);
                }

                last_activity = current_activity;
                tokio::task::yield_now().await;
            }
        }
    }
}

fn prelude(tools: &[ToolDefinition]) -> String {
    let tool_bindings = tools
        .iter()
        .map(|tool| {
            let name = &tool.global_name;
            format!(
                "Object.defineProperty(globalThis.tools, {name:?}, {{\
                   value: async (args = {{}}) => {{\
                     const result = await \
                       Deno.core.ops.op_ankole_tool_call({name:?}, args);\
                     if (!result || result.__ankole_reply !== \"memo\") {{\
                       throw new Error(String(result && result.error));\
                     }}\
                     return result.value;\
                   }},\
                   enumerable: true\
                 }});"
            )
        })
        .collect::<Vec<_>>()
        .join("\n");

    format!(
        "globalThis.tools = {{}};\n\
         {tool_bindings}\n\
         globalThis.text = (value) => {{\
           if (!Deno.core.ops.op_ankole_text(String(value))) {{\
             throw new Error(\"program output limit exceeded\");\
           }}\
         }};\n\
         globalThis.image = (value) => {{\
           if (!Deno.core.ops.op_ankole_image(String(value))) {{\
             throw new Error(\"program output limit exceeded\");\
           }}\
         }};\n\
         (() => {{\n\
           let seed = 0x2F6E2B1;\n\
           Math.random = () => {{\n\
             seed = (seed * 1664525 + 1013904223) >>> 0;\n\
             return seed / 4294967296;\n\
           }};\n\
           const frozenNow = 1735689600000;\n\
           const NativeDate = Date;\n\
           globalThis.Date = class extends NativeDate {{\n\
             constructor(...args) {{\n\
               if (args.length === 0) {{ super(frozenNow); }} else {{ super(...args); }}\n\
             }}\n\
             static now() {{ return frozenNow; }}\n\
           }};\n\
         }})();"
    )
}

fn activity(js_runtime: &mut JsRuntime) -> u64 {
    let op_state = js_runtime.op_state();
    let op_state = op_state.borrow();
    op_state.borrow::<ProgramState>().activity
}

fn has_pending_calls(js_runtime: &mut JsRuntime) -> bool {
    let op_state = js_runtime.op_state();
    let op_state = op_state.borrow();
    !op_state.borrow::<ProgramState>().pending_calls.is_empty()
}

fn has_host_failure(js_runtime: &mut JsRuntime) -> bool {
    let op_state = js_runtime.op_state();
    let op_state = op_state.borrow();
    op_state.borrow::<ProgramState>().failure.is_some()
}

fn set_program_status(js_runtime: &mut JsRuntime, status: ProgramStatus) {
    let op_state = js_runtime.op_state();
    let mut op_state = op_state.borrow_mut();
    op_state.borrow_mut::<ProgramState>().status = status;
}

fn finish(js_runtime: &mut JsRuntime, event_loop_failure: Option<ProgramFailure>) -> RunOutcome {
    let (divergence, failure, status, memo_remaining, pending_calls, output) = {
        let op_state = js_runtime.op_state();
        let mut op_state = op_state.borrow_mut();
        let program = op_state.borrow_mut::<ProgramState>();

        (
            program.divergence.take(),
            program.failure.take(),
            std::mem::replace(&mut program.status, ProgramStatus::Running),
            program.memo.len().saturating_sub(program.memo_cursor),
            std::mem::take(&mut program.pending_calls),
            std::mem::take(&mut program.output),
        )
    };

    let failure = failure
        .or_else(|| {
            divergence.map(|message| ProgramFailure {
                code: "program_replay_diverged".to_string(),
                message: bounded_message(&message),
            })
        })
        .or(event_loop_failure);

    if let Some(failure) = failure {
        return RunOutcome {
            status: "failed".to_string(),
            output,
            pending_calls: Vec::new(),
            error: Some(failure.message),
            error_code: Some(failure.code),
        };
    }

    match status {
        ProgramStatus::Completed if memo_remaining > 0 => RunOutcome {
            status: "failed".to_string(),
            output,
            pending_calls: Vec::new(),
            error: Some(format!(
                "program replay completed with {memo_remaining} unused memo entries"
            )),
            error_code: Some("program_replay_memo_unused".to_string()),
        },

        ProgramStatus::Completed => RunOutcome {
            status: "completed".to_string(),
            output,
            pending_calls: Vec::new(),
            error: None,
            error_code: None,
        },

        ProgramStatus::Failed(message) => RunOutcome {
            status: "failed".to_string(),
            output,
            pending_calls: Vec::new(),
            error: Some(message),
            error_code: Some("program_execution_failed".to_string()),
        },

        ProgramStatus::Running if !pending_calls.is_empty() => RunOutcome {
            status: "pending".to_string(),
            output,
            pending_calls,
            error: None,
            error_code: None,
        },

        ProgramStatus::Running => RunOutcome {
            status: "failed".to_string(),
            output,
            pending_calls: Vec::new(),
            error: Some("program neither completed nor paused".to_string()),
            error_code: Some("program_invalid_terminal_state".to_string()),
        },
    }
}

fn validate_request(request: &RunRequest) -> Result<HashMap<String, ToolIdentity>, ProgramFailure> {
    let max_program_bytes = capped(request.max_program_bytes, DEFAULT_MAX_PROGRAM_BYTES);
    if request.program.len() > max_program_bytes {
        return Err(ProgramFailure {
            code: "program_source_limit_exceeded".to_string(),
            message: format!("program source exceeded {max_program_bytes} bytes"),
        });
    }

    let max_memo_entries = capped(request.max_memo_entries, DEFAULT_MAX_MEMO_ENTRIES);
    if request.memo.len() > max_memo_entries {
        return Err(ProgramFailure {
            code: "program_memo_limit_exceeded".to_string(),
            message: format!("program memo exceeded {max_memo_entries} entries"),
        });
    }

    let memo_bytes = serde_json::to_vec(&request.memo).map_or(usize::MAX, |value| value.len());
    let max_memo_bytes = capped(request.max_memo_bytes, DEFAULT_MAX_MEMO_BYTES);
    if memo_bytes > max_memo_bytes {
        return Err(ProgramFailure {
            code: "program_memo_limit_exceeded".to_string(),
            message: format!("program memo exceeded {max_memo_bytes} bytes"),
        });
    }

    let allowed_tools = validate_tools(&request.tools)?;
    if let Some(entry) = request.memo.iter().find(|entry| {
        !allowed_tools
            .values()
            .any(|identity| identity.namespace == entry.namespace && identity.name == entry.name)
    }) {
        return Err(ProgramFailure {
            code: "program_memo_tool_not_allowed".to_string(),
            message: format!(
                "program memo references a disabled tool: {}",
                qualified_name(entry.namespace.as_deref(), &entry.name)
            ),
        });
    }

    Ok(allowed_tools)
}

fn validate_tools(
    tools: &[ToolDefinition],
) -> Result<HashMap<String, ToolIdentity>, ProgramFailure> {
    if tools.len() > DEFAULT_MAX_TOOLS {
        return Err(ProgramFailure {
            code: "program_tool_limit_exceeded".to_string(),
            message: format!("program tools exceeded {DEFAULT_MAX_TOOLS} entries"),
        });
    }

    let mut global_names = HashMap::with_capacity(tools.len());
    let mut identities = HashSet::with_capacity(tools.len());
    let mut total_bytes = 0usize;
    for tool in tools {
        let identity = ToolIdentity {
            namespace: tool.namespace.clone(),
            name: tool.name.clone(),
        };
        total_bytes = total_bytes
            .saturating_add(tool.namespace.as_ref().map_or(0, String::len))
            .saturating_add(tool.name.len())
            .saturating_add(tool.global_name.len());
        if tool.name.is_empty()
            || tool
                .namespace
                .as_ref()
                .is_some_and(|namespace| namespace.is_empty())
            || tool.global_name.is_empty()
            || tool.global_name.len() > DEFAULT_MAX_TOOL_NAME_BYTES
            || total_bytes > DEFAULT_MAX_TOOL_NAMES_BYTES
            || !identities.insert(identity.clone())
            || global_names
                .insert(tool.global_name.clone(), identity)
                .is_some()
        {
            return Err(ProgramFailure {
                code: "program_invalid_tools".to_string(),
                message: "program tool identities and JavaScript globals must be valid and unique"
                    .to_string(),
            });
        }
    }
    Ok(global_names)
}

fn qualified_name(namespace: Option<&str>, name: &str) -> String {
    namespace.map_or_else(
        || name.to_string(),
        |namespace| format!("{namespace}.{name}"),
    )
}

fn capped(requested: Option<usize>, hard_max: usize) -> usize {
    requested.unwrap_or(hard_max).min(hard_max)
}

fn bounded_message(message: &str) -> String {
    if message.len() <= DEFAULT_MAX_ERROR_BYTES {
        return message.to_string();
    }

    let mut end = DEFAULT_MAX_ERROR_BYTES.saturating_sub('…'.len_utf8());
    while end > 0 && !message.is_char_boundary(end) {
        end -= 1;
    }

    format!("{}…", &message[..end])
}

fn termination_outcome(termination: &AtomicU8) -> Option<RunOutcome> {
    match termination.load(Ordering::SeqCst) {
        TERMINATION_TIMEOUT => Some(failed(
            "program_timeout",
            "program execution exceeded its timeout",
        )),
        TERMINATION_HEAP => Some(failed(
            "program_heap_limit_exceeded",
            "program execution exceeded its heap limit",
        )),
        TERMINATION_CANCELLED => Some(failed(
            "program_cancelled",
            "program execution was cancelled",
        )),
        _none => None,
    }
}

fn safe_finish(
    js_runtime: &mut JsRuntime,
    event_loop_failure: Option<ProgramFailure>,
    execution_phase: &AtomicU8,
) -> RunOutcome {
    match execution_phase.compare_exchange(
        EXECUTION_RUNNING,
        EXECUTION_FINISHING,
        Ordering::SeqCst,
        Ordering::SeqCst,
    ) {
        Ok(_) => finish(js_runtime, event_loop_failure),
        Err(_) => termination_outcome(execution_phase).unwrap_or_else(|| {
            failed(
                "program_invalid_execution_phase",
                "program could not enter its finishing phase",
            )
        }),
    }
}

fn claim_failure(execution_phase: &AtomicU8, code: &str, message: &str) -> RunOutcome {
    match execution_phase.compare_exchange(
        EXECUTION_RUNNING,
        EXECUTION_FINISHING,
        Ordering::SeqCst,
        Ordering::SeqCst,
    ) {
        Ok(_) => failed(code, message),
        Err(_) => termination_outcome(execution_phase)
            .unwrap_or_else(|| failed("program_invalid_execution_phase", message)),
    }
}

struct RunPermit;

impl RunPermit {
    fn acquire() -> Option<Self> {
        ACTIVE_RUNS
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |active| {
                (active < MAX_CONCURRENT_RUNS).then_some(active + 1)
            })
            .ok()
            .map(|_| Self)
    }
}

impl Drop for RunPermit {
    fn drop(&mut self) {
        ACTIVE_RUNS.fetch_sub(1, Ordering::SeqCst);
    }
}

struct RunningRun {
    run_id: String,
    control: Arc<RunControl>,
}

impl RunningRun {
    fn begin(run_id: &str) -> Result<Self, ProgramFailure> {
        validate_run_id(run_id)?;

        let control = Arc::new(RunControl::new());
        let registry = run_registry();
        let mut registry = registry.lock().unwrap_or_else(|error| error.into_inner());

        if registry.contains_key(run_id) {
            return Err(ProgramFailure {
                code: "program_run_id_conflict".to_string(),
                message: "program run id is already active".to_string(),
            });
        }

        registry.insert(run_id.to_string(), Arc::clone(&control));

        Ok(Self {
            run_id: run_id.to_string(),
            control,
        })
    }
}

impl Drop for RunningRun {
    fn drop(&mut self) {
        let registry = run_registry();
        let mut registry = registry.lock().unwrap_or_else(|error| error.into_inner());

        if registry
            .get(&self.run_id)
            .is_some_and(|registered| Arc::ptr_eq(registered, &self.control))
        {
            registry.remove(&self.run_id);
        }
    }
}

fn run_registry() -> &'static Mutex<HashMap<String, Arc<RunControl>>> {
    RUN_REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Cancels a run that has entered native execution.
///
/// A cancellation that races before registration can miss. The BEAM task is
/// still killed, and the native watchdog bounds the rare late-registration
/// race to one execution slot for at most the configured timeout.
pub fn cancel(run_id: &str) -> Result<bool, String> {
    validate_run_id(run_id).map_err(|failure| failure.message)?;

    let control = run_registry()
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .get(run_id)
        .cloned();

    if let Some(control) = control {
        control.terminate(TERMINATION_CANCELLED);
        Ok(true)
    } else {
        Ok(false)
    }
}

fn validate_run_id(run_id: &str) -> Result<(), ProgramFailure> {
    if run_id.is_empty()
        || run_id.len() > MAX_RUN_ID_BYTES
        || !run_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(ProgramFailure {
            code: "program_invalid_run_id".to_string(),
            message: "program run id is invalid".to_string(),
        });
    }

    Ok(())
}

/// JSON boundary used by the NIF layer.
pub fn run_json(run_id: &str, request_json: &str) -> Result<String, String> {
    if request_json.len() > MAX_RUN_REQUEST_BYTES {
        return Err(format!(
            "invalid program run request: exceeds {MAX_RUN_REQUEST_BYTES} bytes"
        ));
    }

    let request: RunRequest = serde_json::from_str(request_json)
        .map_err(|error| format!("invalid program run request: {error}"))?;

    serde_json::to_string(&run_registered(run_id, request))
        .map_err(|error| format!("program outcome encoding failed: {error}"))
}

#[cfg(test)]
mod tests;
