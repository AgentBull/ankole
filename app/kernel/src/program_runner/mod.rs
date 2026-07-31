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
use std::future::Future;
use std::pin::Pin;
use std::rc::Rc;
use std::task::{Context, Poll};
use std::time::Duration;

use deno_core::{JsRuntime, OpState, PollEventLoopOptions, RuntimeOptions, op2};
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;

const DEFAULT_TIMEOUT_MS: u64 = 30_000;
const DEFAULT_HEAP_LIMIT_BYTES: usize = 256 * 1024 * 1024;
const MAX_OUTPUT_PARTS: usize = 256;
const DIVERGENCE_KEY: &str = "__ankole_divergence";

#[derive(Debug, Deserialize)]
pub struct RunRequest {
    pub program: String,
    #[serde(default)]
    pub tools: Vec<String>,
    #[serde(default)]
    pub memo: Vec<MemoEntry>,
    #[serde(default)]
    pub timeout_ms: Option<u64>,
    #[serde(default)]
    pub heap_limit_bytes: Option<usize>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct MemoEntry {
    pub name: String,
    pub arguments: JsonValue,
    pub output: JsonValue,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct PendingCall {
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
}

struct ProgramState {
    memo: Vec<MemoEntry>,
    memo_cursor: usize,
    pending_calls: Vec<PendingCall>,
    output: Vec<OutputPart>,
    activity: u64,
    divergence: Option<String>,
}

impl ProgramState {
    fn new(memo: Vec<MemoEntry>) -> Self {
        Self {
            memo,
            memo_cursor: 0,
            pending_calls: Vec::new(),
            output: Vec::new(),
            activity: 0,
            divergence: None,
        }
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

// Divergence rides back as a sentinel object that the JS binding turns into a
// thrown error, so the op needs no host error type.
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

        if program.memo_cursor < program.memo.len() {
            let entry = &program.memo[program.memo_cursor];

            if entry.name == name && entry.arguments == arguments {
                let output = entry.output.clone();
                program.memo_cursor += 1;
                Reply::Memo(output)
            } else {
                let message = format!(
                    "program replay diverged: expected {}({}), got {}({})",
                    entry.name, entry.arguments, name, arguments
                );
                program.divergence = Some(message.clone());
                Reply::Diverged(message)
            }
        } else {
            program.pending_calls.push(PendingCall { name, arguments });
            Reply::Pend
        }
    };

    match reply {
        Reply::Memo(output) => output,
        Reply::Diverged(message) => serde_json::json!({ DIVERGENCE_KEY: message }),
        Reply::Pend => EternalPend.await,
    }
}

#[op2(fast)]
fn op_ankole_text(state: &mut OpState, #[string] text: String) {
    let program = state.borrow_mut::<ProgramState>();
    program.activity += 1;

    if program.output.len() < MAX_OUTPUT_PARTS {
        program.output.push(OutputPart {
            kind: "text".to_string(),
            value: text,
        });
    }
}

#[op2(fast)]
fn op_ankole_image(state: &mut OpState, #[string] url: String) {
    let program = state.borrow_mut::<ProgramState>();
    program.activity += 1;

    if program.output.len() < MAX_OUTPUT_PARTS {
        program.output.push(OutputPart {
            kind: "image".to_string(),
            value: url,
        });
    }
}

deno_core::extension!(
    ankole_program,
    ops = [op_ankole_tool_call, op_ankole_text, op_ankole_image],
);

/// Runs one program to completion or to its first unanswered tool-call batch.
pub fn run(request: RunRequest) -> RunOutcome {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| execute(request))) {
        Ok(outcome) => outcome,
        Err(_panic) => failed("program runtime panicked"),
    }
}

fn failed(message: &str) -> RunOutcome {
    RunOutcome {
        status: "failed".to_string(),
        output: Vec::new(),
        pending_calls: Vec::new(),
        error: Some(message.to_string()),
    }
}

fn execute(request: RunRequest) -> RunOutcome {
    let timeout = Duration::from_millis(request.timeout_ms.unwrap_or(DEFAULT_TIMEOUT_MS));
    let heap_limit = request.heap_limit_bytes.unwrap_or(DEFAULT_HEAP_LIMIT_BYTES);

    let tokio_runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => return failed(&format!("tokio runtime unavailable: {error}")),
    };
    let _runtime_guard = tokio_runtime.enter();

    let mut js_runtime = JsRuntime::new(RuntimeOptions {
        extensions: vec![ankole_program::init()],
        create_params: Some(deno_core::v8::CreateParams::default().heap_limits(0, heap_limit)),
        ..Default::default()
    });

    // A heap near-limit callback cannot recover the isolate; terminate loudly.
    let isolate_handle = js_runtime.v8_isolate().thread_safe_handle();
    let heap_handle = isolate_handle.clone();
    js_runtime.add_near_heap_limit_callback(move |current, _initial| {
        heap_handle.terminate_execution();
        current * 2
    });

    js_runtime
        .op_state()
        .borrow_mut()
        .put(ProgramState::new(request.memo));

    let watchdog_handle = isolate_handle;
    let (cancel_watchdog, watchdog_cancelled) = std::sync::mpsc::channel::<()>();
    let watchdog = std::thread::spawn(move || {
        if watchdog_cancelled.recv_timeout(timeout).is_err() {
            watchdog_handle.terminate_execution();
        }
    });

    let outcome = tokio_runtime.block_on(drive(&mut js_runtime, &request.program, &request.tools));

    let _ = cancel_watchdog.send(());
    let _ = watchdog.join();

    outcome
}

async fn drive(js_runtime: &mut JsRuntime, program: &str, tools: &[String]) -> RunOutcome {
    if let Err(error) = js_runtime.execute_script("ankole:prelude", prelude(tools)) {
        return failed(&format!("program prelude failed: {error}"));
    }

    let wrapped = format!(
        "globalThis.__ankole_program = (async () => {{\n{program}\n}})();\
         globalThis.__ankole_status = \"running\";\
         globalThis.__ankole_program.then(\
           () => {{ globalThis.__ankole_status = \"completed\"; }},\
           (error) => {{\
             globalThis.__ankole_status = \"failed\";\
             globalThis.__ankole_error = String((error && error.stack) || error);\
           }}\
         );"
    );

    if let Err(error) = js_runtime.execute_script("ankole:program", wrapped) {
        return failed(&format!("program rejected before start: {error}"));
    }

    // The only async ops are tool calls: memoized calls resolve within the
    // tick and unanswered calls pend forever. A Pending event loop with no new
    // op activity between two polls therefore means the program stalled on its
    // pending batch.
    let mut last_activity = activity(js_runtime);

    loop {
        let poll_result = futures_util::future::poll_fn(|cx| {
            Poll::Ready(js_runtime.poll_event_loop(cx, PollEventLoopOptions::default()))
        })
        .await;

        match poll_result {
            Poll::Ready(Ok(())) => break,
            Poll::Ready(Err(error)) => return finish(js_runtime, Some(format!("{error}"))),

            Poll::Pending => {
                let current_activity = activity(js_runtime);

                if current_activity == last_activity && has_pending_calls(js_runtime) {
                    return finish(js_runtime, None);
                }

                last_activity = current_activity;
                tokio::task::yield_now().await;
            }
        }
    }

    finish(js_runtime, None)
}

fn prelude(tools: &[String]) -> String {
    let tool_bindings = tools
        .iter()
        .map(|name| {
            format!(
                "Object.defineProperty(globalThis.tools, {name:?}, {{\
                   value: async (args = {{}}) => {{\
                     const result = await \
                       Deno.core.ops.op_ankole_tool_call({name:?}, args);\
                     if (result && typeof result === \"object\" && \
                         result.{DIVERGENCE_KEY}) {{\
                       throw new Error(result.{DIVERGENCE_KEY});\
                     }}\
                     return result;\
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
         globalThis.text = (value) => Deno.core.ops.op_ankole_text(String(value));\n\
         globalThis.image = (value) => Deno.core.ops.op_ankole_image(String(value));\n\
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

fn read_global_string(js_runtime: &mut JsRuntime, expression: &'static str) -> Option<String> {
    let value = js_runtime.execute_script("ankole:read", expression).ok()?;
    deno_core::scope!(scope, js_runtime);
    let local = deno_core::v8::Local::new(scope, value);

    if local.is_undefined() || local.is_null() {
        return None;
    }

    Some(local.to_rust_string_lossy(scope))
}

fn finish(js_runtime: &mut JsRuntime, event_loop_error: Option<String>) -> RunOutcome {
    let status = read_global_string(js_runtime, "globalThis.__ankole_status");

    let (divergence, pending_calls, output) = {
        let op_state = js_runtime.op_state();
        let mut op_state = op_state.borrow_mut();
        let program = op_state.borrow_mut::<ProgramState>();

        (
            program.divergence.take(),
            std::mem::take(&mut program.pending_calls),
            std::mem::take(&mut program.output),
        )
    };

    match (divergence, status.as_deref(), event_loop_error) {
        (Some(message), _status, _loop_error) => RunOutcome {
            status: "failed".to_string(),
            output,
            pending_calls: Vec::new(),
            error: Some(message),
        },

        (None, Some("completed"), _loop_error) => RunOutcome {
            status: "completed".to_string(),
            output,
            pending_calls: Vec::new(),
            error: None,
        },

        (None, Some("failed"), _loop_error) => {
            let message = read_global_string(js_runtime, "globalThis.__ankole_error")
                .unwrap_or_else(|| "program failed".to_string());

            RunOutcome {
                status: "failed".to_string(),
                output,
                pending_calls: Vec::new(),
                error: Some(message),
            }
        }

        (None, _status, Some(loop_error)) => RunOutcome {
            status: "failed".to_string(),
            output,
            pending_calls: Vec::new(),
            error: Some(loop_error),
        },

        (None, _status, None) if !pending_calls.is_empty() => RunOutcome {
            status: "pending".to_string(),
            output,
            pending_calls,
            error: None,
        },

        (None, _status, None) => RunOutcome {
            status: "failed".to_string(),
            output,
            pending_calls: Vec::new(),
            error: Some("program neither completed nor paused".to_string()),
        },
    }
}

/// JSON boundary used by the NIF layer.
pub fn run_json(request_json: &str) -> Result<String, String> {
    let request: RunRequest = serde_json::from_str(request_json)
        .map_err(|error| format!("invalid program run request: {error}"))?;

    serde_json::to_string(&run(request))
        .map_err(|error| format!("program outcome encoding failed: {error}"))
}

#[cfg(test)]
mod tests;
