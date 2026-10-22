//! One live, capability-only V8 isolate for one Applet route invocation.
//!
//! Native threads own isolates. BEAM callers only send capability replies and
//! receive events; waiting never reserves a dirty scheduler. No state is replayed.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use deno_core::{JsRuntime, OpState, PollEventLoopOptions, RuntimeOptions, op2, v8};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::{Notify, oneshot};

use crate::isolate_control::*;

mod memory;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub source: String,
    #[serde(default)]
    pub inspect: bool,
    #[serde(default)]
    pub context: Value,
    #[serde(default = "default_timeout")]
    pub timeout_ms: u64,
    #[serde(default = "default_heap")]
    pub heap_mb: usize,
}

fn default_timeout() -> u64 {
    60_000
}
fn default_heap() -> usize {
    128
}

// Match the existing native runner's production admission count. Every route
// and inspection shares these slots, including direct NIF callers.
const MAX_CONCURRENT_RUNS: usize = 4;
static ACTIVE_RUNS: AtomicUsize = AtomicUsize::new(0);
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

/// Events use JSON values, with base64 only at the file byte boundary.
#[derive(Debug)]
pub enum Event {
    Call {
        id: u64,
        operation: String,
        arguments: Value,
    },
    Done(Value),
}

pub type Sink = Arc<dyn Fn(Event) + Send + Sync>;

/// The resource has the same cancellation authority as its isolate.
#[derive(Clone)]
pub struct Handle(Arc<Invocation>);

type Decode<Value> = Box<dyn FnOnce() -> Result<Value, String> + Send>;

enum Reply {
    Value(Value),
    Decode(Decode<Value>),
}

struct Invocation {
    control: Arc<RunControl>,
    replies: Mutex<HashMap<u64, oneshot::Sender<Reply>>>,
    started: Instant,
    next_id: AtomicU64,
    stopped: Notify,
    inspect_only: AtomicBool,
    inspect_call_attempted: AtomicBool,
    get_route: AtomicBool,
    sink: Sink,
}

impl Handle {
    pub fn cancel(&self) {
        self.0.control.terminate(TERMINATION_CANCELLED);
        self.0.stopped.notify_one();
    }

    pub fn reply(&self, id: u64, reply: Value) -> bool {
        self.send_reply(id, Reply::Value(reply))
    }

    /// The invocation thread decodes a retained transport value after receipt.
    pub fn reply_with(
        &self,
        id: u64,
        decode: impl FnOnce() -> Result<Value, String> + Send + 'static,
    ) -> bool {
        self.send_reply(id, Reply::Decode(Box::new(decode)))
    }

    fn send_reply(&self, id: u64, reply: Reply) -> bool {
        self.0
            .replies
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&id)
            .is_some_and(|sender| sender.send(reply).is_ok())
    }
}

#[derive(Debug)]
pub enum StartError {
    Spawn(String),
    Busy(Value),
}

/// Uses the same invocation owner and validation as retained transport requests.
/// The handle exists before execution, so cancellation cannot miss registration.
pub fn start(request: Request, sink: Sink) -> Result<Handle, StartError> {
    start_with(move || Ok(request), sink)
}

fn validate_limits(request: &Request) -> Result<(), String> {
    if request.timeout_ms == 0
        || request.heap_mb == 0
        || request.heap_mb.checked_mul(1024 * 1024).is_none()
    {
        return Err("timeout_ms and heap_mb must be positive integers".into());
    }
    Ok(())
}

/// Retained transport data enters the same invocation owner as typed requests.
pub fn start_with(
    decode: impl FnOnce() -> Result<Request, String> + Send + 'static,
    sink: Sink,
) -> Result<Handle, StartError> {
    let invocation = Arc::new(Invocation {
        control: Arc::new(RunControl::new()),
        replies: Mutex::new(HashMap::new()),
        started: Instant::now(),
        next_id: AtomicU64::new(1),
        stopped: Notify::new(),
        inspect_only: AtomicBool::new(true),
        inspect_call_attempted: AtomicBool::new(false),
        get_route: AtomicBool::new(false),
        sink,
    });
    let handle = Handle(Arc::clone(&invocation));
    let Some(permit) = RunPermit::acquire() else {
        invocation
            .control
            .execution_phase
            .store(EXECUTION_DONE, Ordering::SeqCst);
        return Err(StartError::Busy(failure(
            503,
            "applet_busy",
            "Applet runtime is at capacity",
        )));
    };
    std::thread::Builder::new()
        .name("ankole-applet".into())
        .spawn(move || {
            let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                if let Some(outcome) = termination(&invocation.control) {
                    return outcome;
                }
                match decode().and_then(|request| {
                    validate_limits(&request)?;
                    Ok(request)
                }) {
                    Ok(request) => execute(request, &invocation),
                    Err(error) => failure(
                        500,
                        "handler_error",
                        &format!("Invalid Applet runtime request: {error}"),
                    ),
                }
            }))
            .unwrap_or_else(|_| failure(500, "handler_error", "Applet runtime failed"));
            invocation
                .replies
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clear();
            invocation
                .control
                .execution_phase
                .store(EXECUTION_DONE, Ordering::SeqCst);
            drop(permit);
            (invocation.sink)(Event::Done(outcome));
        })
        .map_err(|error| StartError::Spawn(format!("cannot start applet runtime: {error}")))?;
    Ok(handle)
}

struct State {
    invocation: Arc<Invocation>,
    logs: Vec<Value>,
    memory: Arc<memory::Budget>,
}

#[op2(fast)]
fn op_applet_inspect_guard(state: &mut OpState) -> bool {
    let invocation = &state.borrow::<State>().invocation;
    let inspect = invocation.inspect_only.load(Ordering::SeqCst);
    if inspect {
        invocation
            .inspect_call_attempted
            .store(true, Ordering::SeqCst);
    }
    inspect
}

#[op2]
#[serde]
async fn op_applet_call(
    state: Rc<RefCell<OpState>>,
    #[string] operation: String,
    #[string] arguments: String,
) -> serde_json::Value {
    let argument_bytes = arguments.len();
    let arguments: Value = match serde_json::from_str(&arguments) {
        Ok(arguments) => arguments,
        Err(_) => {
            return json!({"error":{"status":500,"code":"handler_error","message":"Capability arguments must be JSON"}});
        }
    };
    let (invocation, memory) = {
        let state = state.borrow();
        let state = state.borrow::<State>();
        (Arc::clone(&state.invocation), Arc::clone(&state.memory))
    };
    // Charge outstanding transport values until their reply. The count has no
    // separate quota; it uses the same configured invocation memory budget.
    let Some(_arguments) = memory.retain(
        argument_bytes
            .saturating_mul(3)
            .saturating_add(value_memory(&arguments)),
    ) else {
        return json!({"error":{"status":500,"code":"handler_out_of_memory","message":"Applet memory limit exceeded"}});
    };
    if invocation.inspect_only.load(Ordering::SeqCst) {
        invocation
            .inspect_call_attempted
            .store(true, Ordering::SeqCst);
        return json!({"error":{"status":500,"code":"inspect_only","message":"Capabilities are unavailable during module inspection"}});
    }
    if !matches!(
        operation.as_str(),
        "db.schema"
            | "db.query"
            | "db.aggregate"
            | "db.write"
            | "file.list"
            | "file.read"
            | "file.write"
            | "ai.generateText"
    ) {
        return json!({"error":{"status":500,"code":"handler_error","message":"Unknown Applet capability"}});
    }
    if invocation.get_route.load(Ordering::SeqCst)
        && matches!(operation.as_str(), "db.write" | "file.write")
    {
        return json!({"error":{"status":500,"code":"read_only_route","message":"GET routes cannot write data"}});
    }
    let id = invocation.next_id.fetch_add(1, Ordering::SeqCst);
    let (sender, receiver) = oneshot::channel();
    invocation
        .replies
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(id, sender);
    (invocation.sink)(Event::Call {
        id,
        operation,
        arguments,
    });
    match receiver.await {
        Ok(Reply::Value(value)) => value,
        Ok(Reply::Decode(decode)) => decode().unwrap_or_else(|_| {
            json!({
                "error": {
                    "status": 500,
                    "code": "handler_error",
                    "message": "Invalid capability reply"
                }
            })
        }),
        Err(_) => {
            json!({"error":{"status":500,"code":"handler_error","message":"Applet invocation ended"}})
        }
    }
}

#[op2(fast)]
fn op_applet_console(state: &mut OpState, #[string] level: String, #[string] message: String) {
    let state = state.borrow_mut::<State>();
    let bytes = level
        .capacity()
        .saturating_add(message.capacity())
        .saturating_add(256);
    if state.memory.charge_retained(bytes) {
        state.logs.push(json!({"level": level, "message": message}));
    }
}

deno_core::extension!(
    ankole_applet,
    ops = [op_applet_call, op_applet_console, op_applet_inspect_guard]
);

fn execute(request: Request, invocation: &Arc<Invocation>) -> Value {
    let started = invocation.started;
    let timeout = Duration::from_millis(request.timeout_ms);
    if let Some(outcome) = termination(&invocation.control) {
        return outcome;
    }
    if started.elapsed() >= timeout {
        invocation.control.terminate(TERMINATION_TIMEOUT);
        return termination(&invocation.control).unwrap();
    }
    let heap_limit = request.heap_mb * 1024 * 1024;
    let memory = memory::Budget::new(heap_limit, Arc::clone(&invocation.control));
    let tokio = match tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()
    {
        Ok(runtime) => runtime,
        Err(_) => return failure(500, "handler_error", "Applet runtime unavailable"),
    };
    let _entered = tokio.enter();
    let mut runtime = JsRuntime::new(RuntimeOptions {
        extensions: vec![ankole_applet::init()],
        create_params: Some(
            v8::CreateParams::default()
                .heap_limits(0, heap_limit.max(16 * 1024 * 1024))
                .array_buffer_allocator(memory.allocator()),
        ),
        ..Default::default()
    });
    runtime.v8_isolate().set_allow_atomics_wait(false);
    invocation
        .control
        .install_isolate(runtime.v8_isolate().thread_safe_handle());
    let heap_control = Arc::clone(&invocation.control);
    runtime.add_near_heap_limit_callback(move |current, _initial| {
        heap_control.terminate(TERMINATION_HEAP);
        current.saturating_mul(2)
    });
    runtime.op_state().borrow_mut().put(State {
        invocation: Arc::clone(invocation),
        logs: Vec::new(),
        memory: Arc::clone(&memory),
    });
    memory.check_now(runtime.v8_isolate());
    let watchdog_control = Arc::clone(&invocation.control);
    let watchdog_memory = Arc::clone(&memory);
    let watchdog_invocation = Arc::clone(invocation);
    let (stop, stopped) = std::sync::mpsc::channel();
    let watchdog = std::thread::spawn(move || {
        loop {
            match stopped.recv_timeout(Duration::from_millis(2)) {
                Ok(()) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            }
            if started.elapsed() >= timeout {
                watchdog_control.terminate(TERMINATION_TIMEOUT);
                watchdog_invocation.stopped.notify_one();
                break;
            }
            watchdog_memory.check();
            if watchdog_control.execution_phase.load(Ordering::SeqCst) != EXECUTION_RUNNING {
                watchdog_invocation.stopped.notify_one();
                break;
            }
        }
    });
    let mut outcome = tokio.block_on(drive(&mut runtime, &request, invocation));
    // Claim the terminal state before native cleanup. Termination can no longer
    // race the final read or run after the isolate has been released.
    let phase = invocation.control.execution_phase.compare_exchange(
        EXECUTION_RUNNING,
        EXECUTION_FINISHING,
        Ordering::SeqCst,
        Ordering::SeqCst,
    );
    if phase.is_err() {
        outcome = termination(&invocation.control).unwrap_or(outcome);
    }
    let logs = std::mem::take(&mut runtime.op_state().borrow_mut().borrow_mut::<State>().logs);
    outcome["logs"] = Value::Array(logs);
    let _ = stop.send(());
    let _ = watchdog.join();
    invocation.control.clear_isolate();
    outcome
}

async fn drive(runtime: &mut JsRuntime, request: &Request, invocation: &Arc<Invocation>) -> Value {
    match drive_inner(runtime, request, invocation).await {
        Ok(outcome) => outcome,
        Err(reason) => {
            if let Some(outcome) = termination(&invocation.control) {
                return outcome;
            }
            let mut outcome = failure(
                if request.inspect { 400 } else { 500 },
                if request.inspect {
                    "invalid_applet_routes"
                } else {
                    "handler_error"
                },
                if request.inspect {
                    &reason
                } else {
                    "Applet handler failed"
                },
            );
            outcome["debug"] = json!({"message": bounded(&reason), "stack": bounded(&reason)});
            outcome
        }
    }
}

async fn drive_inner(
    runtime: &mut JsRuntime,
    request: &Request,
    invocation: &Arc<Invocation>,
) -> Result<Value, String> {
    if let Some(outcome) = termination(&invocation.control) {
        return Ok(outcome);
    }
    validate_module(&request.source)?;
    let bootstrap = runtime
        .execute_script("ankole:bootstrap", include_str!("bootstrap.js"))
        .map_err(|e| e.to_string())?;
    let module_url = deno_core::ModuleSpecifier::parse("applet:///server/main.js").unwrap();
    let module = runtime
        .load_side_es_module_from_code(&module_url, request.source.clone())
        .await
        .map_err(|e| e.to_string())?;
    let evaluation = runtime.mod_evaluate(module);
    let evaluation = Box::pin(evaluation);
    settle(runtime, evaluation, invocation).await?;
    if invocation.inspect_call_attempted.load(Ordering::SeqCst) {
        return Err("inspect_only: top-level code cannot call AnkoleRuntime".into());
    }
    let namespace = runtime
        .get_module_namespace(module)
        .map_err(|e| e.to_string())?;
    let (routes, keys_json) = {
        deno_core::scope!(scope, runtime);
        v8::tc_scope!(let scope, scope);
        let namespace = v8::Local::new(scope, &namespace);
        let default = v8::String::new(scope, "default").unwrap();
        let routes = namespace
            .get(scope, default.into())
            .ok_or("default export is missing")?;
        let bootstrap = v8::Local::new(scope, &bootstrap)
            .to_object(scope)
            .ok_or("bootstrap unavailable")?;
        let name = v8::String::new(scope, "validate").unwrap();
        let validate = bootstrap
            .get(scope, name.into())
            .and_then(|v| v8::Local::<v8::Function>::try_from(v).ok())
            .ok_or("route validator unavailable")?;
        let undefined = v8::undefined(scope).into();
        let encoded = match validate.call(scope, undefined, &[routes]) {
            Some(value) => value,
            None => {
                let reason = scope
                    .exception()
                    .map(|exception| exception.to_rust_string_lossy(scope))
                    .unwrap_or_else(|| "default export must contain function routes".into());
                return Err(reason);
            }
        };
        (
            v8::Global::new(scope, routes),
            encoded.to_rust_string_lossy(scope),
        )
    };
    let keys: Vec<String> = serde_json::from_str(&keys_json).map_err(|e| e.to_string())?;
    let routes_metadata = parse_routes(&keys)?;
    if invocation.inspect_call_attempted.load(Ordering::SeqCst) {
        return Err("inspect_only: top-level code cannot call AnkoleRuntime".into());
    }
    if request.inspect {
        return Ok(json!({"status":200,"routes":keys}));
    }
    let method = request
        .context
        .get("method")
        .and_then(Value::as_str)
        .ok_or("request method is missing")?;
    let path = request
        .context
        .get("path")
        .and_then(Value::as_str)
        .ok_or("request path is missing")?;
    let matched = match match_route(&routes_metadata, method, path) {
        Ok(matched) => matched,
        Err(reason) => return Ok(failure(400, "invalid_request", &reason)),
    };
    let (route, params) = match matched {
        Match::Route(route, params) => (route, params),
        Match::Missing => return Ok(failure(404, "route_not_found", "Applet route not found")),
        Match::Method => return Ok(failure(405, "method_not_allowed", "Method not allowed")),
    };
    let mut context = request.context.clone();
    context["params"] = serde_json::to_value(params).unwrap();
    invocation
        .get_route
        .store(method == "GET", Ordering::SeqCst);
    invocation.inspect_only.store(false, Ordering::SeqCst);
    let promise = {
        deno_core::scope!(scope, runtime);
        let bootstrap = v8::Local::new(scope, &bootstrap)
            .to_object(scope)
            .ok_or("bootstrap unavailable")?;
        let name = v8::String::new(scope, "invoke").unwrap();
        let invoke = bootstrap
            .get(scope, name.into())
            .and_then(|v| v8::Local::<v8::Function>::try_from(v).ok())
            .ok_or("handler invoker unavailable")?;
        let routes = v8::Local::new(scope, &routes);
        let key = v8::String::new(scope, &route.key).ok_or("route key allocation failed")?;
        let input =
            v8::String::new(scope, &context.to_string()).ok_or("request allocation failed")?;
        let undefined = v8::undefined(scope).into();
        let result = invoke
            .call(scope, undefined, &[routes, key.into(), input.into()])
            .ok_or("handler could not start")?;
        v8::Global::new(scope, result)
    };
    let resolution = Box::pin(runtime.resolve(promise));
    let result = settle(runtime, resolution, invocation).await?;
    deno_core::scope!(scope, runtime);
    let result = v8::Local::new(scope, result);
    serde_json::from_str(&result.to_rust_string_lossy(scope)).map_err(|e| e.to_string())
}

async fn settle<T, E: std::fmt::Display>(
    runtime: &mut JsRuntime,
    mut resolution: std::pin::Pin<Box<impl std::future::Future<Output = Result<T, E>>>>,
    invocation: &Arc<Invocation>,
) -> Result<T, String> {
    use std::task::Poll;
    let stopped = invocation.stopped.notified();
    tokio::pin!(stopped);
    futures_util::future::poll_fn(|cx| {
        if let Some(outcome) = termination(&invocation.control) {
            return Poll::Ready(Err(outcome["body"]["error"]["code"]
                .as_str()
                .unwrap_or("handler_error")
                .to_owned()));
        }
        if let Poll::Ready(result) = resolution.as_mut().poll(cx) {
            return Poll::Ready(result.map_err(|e| e.to_string()));
        }
        if let Poll::Ready(Err(error)) =
            runtime.poll_event_loop(cx, PollEventLoopOptions::default())
        {
            return Poll::Ready(Err(error.to_string()));
        }
        // A host reply can settle a promise during this event-loop poll.
        if let Poll::Ready(result) = resolution.as_mut().poll(cx) {
            return Poll::Ready(result.map_err(|e| e.to_string()));
        }
        if stopped.as_mut().poll(cx).is_ready() {
            cx.waker().wake_by_ref();
        }
        Poll::Pending
    })
    .await
}

fn termination(control: &RunControl) -> Option<Value> {
    match control.execution_phase.load(Ordering::SeqCst) {
        TERMINATION_TIMEOUT => Some(failure(504, "handler_timeout", "Applet handler timed out")),
        TERMINATION_HEAP => Some(failure(
            500,
            "handler_out_of_memory",
            "Applet memory limit exceeded",
        )),
        TERMINATION_CANCELLED => Some(failure(
            499,
            "handler_cancelled",
            "Applet invocation cancelled",
        )),
        _ => None,
    }
}
fn failure(status: u16, code: &str, message: &str) -> Value {
    json!({"status":status,"body":{"error":{"code":code,"message":bounded(message)}}})
}
fn bounded(value: &str) -> String {
    value.chars().take(16_384).collect()
}

#[derive(Debug)]
struct Route {
    key: String,
    method: String,
    segments: Vec<Segment>,
}
#[derive(Debug)]
enum Segment {
    Literal(String),
    Parameter(String),
}
enum Match<'a> {
    Route(&'a Route, BTreeMap<String, String>),
    Missing,
    Method,
}

fn parse_routes(keys: &[String]) -> Result<Vec<Route>, String> {
    let mut patterns = HashSet::new();
    let mut routes = Vec::new();
    for key in keys {
        let (method, path) = key
            .split_once(' ')
            .ok_or_else(|| format!("invalid route: {key}"))?;
        if !matches!(method, "GET" | "POST" | "PUT" | "PATCH" | "DELETE") || !path.starts_with('/')
        {
            return Err(format!("invalid route: {key}"));
        }
        let mut names = HashSet::new();
        let mut pattern = method.to_owned();
        let mut segments = Vec::new();
        for part in if path == "/" {
            Vec::new()
        } else {
            path[1..].split('/').collect()
        } {
            pattern.push('/');
            if let Some(name) = part.strip_prefix(':') {
                if name.is_empty() || name.contains(':') || !names.insert(name.to_owned()) {
                    return Err(format!("invalid route parameter: {key}"));
                }
                pattern.push(':');
                segments.push(Segment::Parameter(name.into()));
            } else {
                pattern.push_str(part);
                segments.push(Segment::Literal(part.into()));
            }
        }
        if !patterns.insert(pattern) {
            return Err(format!("conflicting route: {key}"));
        }
        routes.push(Route {
            key: key.clone(),
            method: method.into(),
            segments,
        });
    }
    // Lexicographic specificity chooses a literal before a parameter at the
    // first differing segment. Declaration order cannot affect matching.
    routes.sort_by(|a, b| {
        a.segments
            .iter()
            .map(|s| matches!(s, Segment::Literal(_)))
            .cmp(b.segments.iter().map(|s| matches!(s, Segment::Literal(_))))
            .reverse()
    });
    Ok(routes)
}

fn match_route<'a>(routes: &'a [Route], method: &str, path: &str) -> Result<Match<'a>, String> {
    if !path.starts_with('/') {
        return Ok(Match::Missing);
    }
    let parts: Vec<&str> = if path == "/" {
        Vec::new()
    } else {
        path[1..].split('/').collect()
    };
    let parts = parts
        .into_iter()
        .map(decode_segment)
        .collect::<Result<Vec<_>, _>>()?;
    let mut path_exists = false;
    for route in routes {
        if route.segments.len() != parts.len() {
            continue;
        }
        let mut params = BTreeMap::new();
        let mut matches = true;
        for (segment, part) in route.segments.iter().zip(&parts) {
            match segment {
                Segment::Literal(value) if value != part => {
                    matches = false;
                    break;
                }
                Segment::Literal(_) => {}
                Segment::Parameter(name) => {
                    if part.is_empty() {
                        matches = false;
                        break;
                    }
                    params.insert(name.clone(), part.clone());
                }
            }
        }
        if matches {
            path_exists = true;
            if route.method == method {
                return Ok(Match::Route(route, params));
            }
        }
    }
    Ok(if path_exists {
        Match::Method
    } else {
        Match::Missing
    })
}

fn decode_segment(input: &str) -> Result<String, String> {
    let mut bytes = Vec::new();
    let mut input = input.bytes();
    while let Some(byte) = input.next() {
        if byte == b'%' {
            let high = input.next().and_then(|b| (b as char).to_digit(16));
            let low = input.next().and_then(|b| (b as char).to_digit(16));
            match (high, low) {
                (Some(h), Some(l)) => bytes.push((h * 16 + l) as u8),
                _ => return Err("invalid encoded path parameter".into()),
            }
        } else {
            bytes.push(byte);
        }
    }
    String::from_utf8(bytes).map_err(|_| "path parameter is not UTF-8".into())
}

#[cfg(test)]
mod tests;

/// Parse the complete bundle, including unexecuted handlers. A module loader
/// is also absent, so evaluated strings have no path to host modules.
fn validate_module(source: &str) -> Result<(), String> {
    use deno_ast::swc::ast::{ExportAll, Import, ImportDecl, NamedExport};
    use deno_ast::swc::ecma_visit::{Visit, VisitWith};
    struct Imports(bool);
    impl Visit for Imports {
        fn visit_import(&mut self, _: &Import) {
            self.0 = true;
        }
        fn visit_import_decl(&mut self, _: &ImportDecl) {
            self.0 = true;
        }
        fn visit_named_export(&mut self, export: &NamedExport) {
            if export.src.is_some() {
                self.0 = true;
            }
        }
        fn visit_export_all(&mut self, _: &ExportAll) {
            self.0 = true;
        }
    }
    let parsed = deno_ast::parse_module(deno_ast::ParseParams {
        specifier: deno_ast::ModuleSpecifier::parse("applet:///server/main.js").unwrap(),
        text: Arc::from(source),
        media_type: deno_ast::MediaType::JavaScript,
        capture_tokens: false,
        scope_analysis: false,
        maybe_syntax: None,
    })
    .map_err(|e| e.to_string())?;
    let mut imports = Imports(false);
    parsed.program().visit_with(&mut imports);
    if imports.0 {
        Err("Applet bundles cannot contain static or dynamic imports".into())
    } else {
        Ok(())
    }
}

fn value_memory(value: &Value) -> usize {
    match value {
        Value::String(value) => value.capacity(),
        Value::Array(values) => values
            .capacity()
            .saturating_mul(std::mem::size_of::<Value>())
            .saturating_add(values.iter().map(value_memory).sum::<usize>()),
        Value::Object(values) => values.iter().fold(0usize, |total, (key, value)| {
            total
                .saturating_add(128)
                .saturating_add(key.capacity())
                .saturating_add(value_memory(value))
        }),
        _ => 0,
    }
}
