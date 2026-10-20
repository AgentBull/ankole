use super::*;
use std::sync::mpsc::{self, Receiver};

fn launch(
    source: &str,
    context: Value,
    inspect: bool,
    timeout_ms: u64,
    heap_mb: usize,
) -> (Handle, Receiver<Event>) {
    let request = Request {
        source: source.into(),
        context,
        inspect,
        timeout_ms,
        heap_mb,
    };
    launch_with(move || Ok(request))
}

fn launch_with(
    decode: impl FnOnce() -> Result<Request, String> + Send + 'static,
) -> (Handle, Receiver<Event>) {
    // Parallel test callers wait for the same admission slots production uses.
    // The explicit overload test below observes rejection without retrying.
    let decode = Arc::new(Mutex::new(Some(decode)));
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let (sender, receiver) = mpsc::channel();
        let busy = Arc::new(AtomicBool::new(false));
        let observer = Arc::clone(&busy);
        let decode = Arc::clone(&decode);
        let handle = start_with(move || decode.lock().unwrap().take().unwrap()(),
            Arc::new(move |event| {
                if matches!(&event, Event::Done(value) if value["body"]["error"]["code"] == "applet_busy") {
                    observer.store(true, Ordering::SeqCst);
                }
                let _ = sender.send(event);
            })).unwrap();
        if !busy.load(Ordering::SeqCst) {
            return (handle, receiver);
        }
        assert!(
            Instant::now() < deadline,
            "native Applet slots did not drain"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}
fn context(method: &str, path: &str) -> Value {
    json!({"method":method,"path":path,"query":{"tag":["one","two"]},"principal":{"uid":"human-1","kind":"human"},"applet":{"pageId":"page-1","revision":3},"timezone":"Asia/Singapore"})
}
fn finish(receiver: &Receiver<Event>) -> Value {
    match receiver.recv_timeout(Duration::from_secs(10)).unwrap() {
        Event::Done(value) => value,
        event => panic!("unexpected event: {event:?}"),
    }
}
fn run(source: &str, method: &str, path: &str) -> Value {
    let (_handle, events) = launch(source, context(method, path), false, 2_000, 32);
    finish(&events)
}

#[test]
fn routes_use_literals_first_and_decode_parameters_with_request_context() {
    let source = r#"export default {'GET /orders/:id': ({params,query,principal,applet,timezone}) => ({params,query,principal,applet,timezone}), 'GET /orders/new': () => 'new'}"#;
    assert_eq!(run(source, "GET", "/orders/new")["body"], "new");
    let output = run(source, "GET", "/orders/a%2Fb%20%E4%B8%AD");
    assert_eq!(output["body"]["params"]["id"], "a/b 中");
    assert_eq!(output["body"]["query"]["tag"], json!(["one", "two"]));
    assert_eq!(output["body"]["principal"]["uid"], "human-1");
    assert_eq!(output["body"]["applet"]["revision"], 3);
    assert_eq!(output["body"]["timezone"], "Asia/Singapore");
    assert_eq!(run(source, "POST", "/orders/new")["status"], 405);
    assert_eq!(run(source, "GET", "/missing")["status"], 404);
}

#[test]
fn inspection_validates_without_executing_handlers() {
    let (_handle, events) = launch(
        "export default {'GET /':()=>{throw Error('not run')}, 'POST /orders/:id':()=>{}}",
        Value::Null,
        true,
        2000,
        32,
    );
    assert_eq!(
        finish(&events)["routes"],
        json!(["GET /", "POST /orders/:id"])
    );
    for source in [
        "export default []",
        "export default null",
        "export default {'GET /': 1}",
        "export default {'get /':()=>1}",
        "export default {'GET x':()=>1}",
        "export default {'GET /:id':()=>1, 'GET /:name':()=>2}",
        "export default {'GET /:id/:id':()=>1}",
    ] {
        let (_handle, events) = launch(source, Value::Null, true, 2000, 32);
        assert_eq!(finish(&events)["status"], 400, "{source}");
    }
}

#[test]
fn rejects_imports_in_unexecuted_code_but_not_strings_or_comments() {
    for source in [
        "import 'file:///etc/passwd'; export default {}",
        "export * from 'file:///etc/passwd'",
        "export {x} from 'file:///etc/passwd'",
        "export default {'GET /':()=>import('file:///etc/passwd')}",
        "export default {'GET /':x=>import(x.path)}",
        "export default {'GET /':x=>`${import(x.path)}`}",
    ] {
        let (_handle, events) = launch(source, Value::Null, true, 2000, 32);
        let output = finish(&events);
        assert_eq!(output["status"], 400, "{output}");
        assert!(
            output["body"]["error"]["message"]
                .as_str()
                .unwrap()
                .contains("imports")
        );
    }
    let source = "/* import('x') */ const text = `import('x')`; export default {'GET /':()=>text}";
    assert_eq!(run(source, "GET", "/")["body"], "import('x')");
}

#[test]
fn inspect_capability_attempt_is_not_hidden_by_catch_or_unawaited_promise() {
    for source in [
        "try { await AnkoleRuntime.db.query('t',{}) } catch {} export default {}",
        "AnkoleRuntime.db.query('t',{}).catch(()=>{}); export default {}",
        "Object.keys = () => []; AnkoleRuntime.file.list('p').catch(()=>{}); export default {}",
        "try { await AnkoleRuntime.file.write('p',{name:'x',bytes:'bad'}) } catch {} export default {}",
        "try { AnkoleRuntime.file.write('p',{get bytes(){throw Error('invalid bytes')}}) } catch {} export default {}",
    ] {
        let (_handle, events) = launch(source, Value::Null, true, 2000, 32);
        let output = finish(&events);
        assert_eq!(output["status"], 400, "{output}");
    }
}

#[test]
fn one_live_isolate_waits_without_replaying_side_effects() {
    let source = "let n=0; export default {'POST /':async()=>{ n++; const first=await AnkoleRuntime.db.write('t',{value:n}); const second=await AnkoleRuntime.db.query('t',{}); return {n,first,second} }}";
    let (handle, events) = launch(source, context("POST", "/"), false, 2000, 32);
    match events.recv_timeout(Duration::from_secs(5)).unwrap() {
        Event::Call {
            id,
            operation,
            arguments,
        } => {
            assert_eq!(operation, "db.write");
            assert_eq!(arguments[1]["value"], 1);
            assert!(handle.reply(id, json!({"value":{"written":true}})));
        }
        event => panic!("{event:?}"),
    }
    match events.recv_timeout(Duration::from_secs(5)).unwrap() {
        Event::Call { id, operation, .. } => {
            assert_eq!(operation, "db.query");
            assert!(handle.reply(id, json!({"value":{"records":[]}})));
        }
        event => panic!("{event:?}"),
    }
    let output = finish(&events);
    assert_eq!(
        output["body"],
        json!({"n":1,"first":{"written":true},"second":{"records":[]}})
    );
}

#[test]
fn independent_invocations_have_fresh_globals_and_real_clock_and_random() {
    let source = "globalThis.count=(globalThis.count||0)+1; export default {'GET /':()=>({count:globalThis.count,now:Date.now(),random:Math.random()})}";
    let first = run(source, "GET", "/");
    let second = run(source, "GET", "/");
    assert_eq!(first["body"]["count"], 1);
    assert_eq!(second["body"]["count"], 1);
    assert!(first["body"]["now"].as_u64().unwrap() > 1_735_689_600_000);
    assert_ne!(first["body"]["random"], second["body"]["random"]);
}

#[test]
fn globals_do_not_expose_host_facilities() {
    let source = "export default {'GET /':()=>Object.fromEntries(['fetch','Deno','process','require','setTimeout','setInterval','Request','Response','URL','TextEncoder','crypto','structuredClone','WebAssembly'].map(k=>[k,typeof globalThis[k]]))}";
    let result = run(source, "GET", "/");
    for (name, value) in result["body"].as_object().unwrap() {
        assert_eq!(value, "undefined", "{name}");
    }
    assert_eq!(
        run(
            "export default {'GET /':()=>new Intl.DateTimeFormat('en',{timeZone:'Asia/Singapore'}).resolvedOptions().timeZone}",
            "GET",
            "/"
        )["body"],
        "Asia/Singapore"
    );
}

#[test]
fn readonly_routes_and_capability_errors_keep_the_domain_status() {
    let output = run(
        "export default {'GET /':()=>AnkoleRuntime.db.write('t',{})}",
        "GET",
        "/",
    );
    assert_eq!(output["status"], 500);
    assert_eq!(output["body"]["error"]["code"], "read_only_route");
    let (handle, events) = launch(
        "export default {'POST /':()=>AnkoleRuntime.db.write('t',{})}",
        context("POST", "/"),
        false,
        2000,
        32,
    );
    if let Event::Call { id, .. } = events.recv_timeout(Duration::from_secs(5)).unwrap() {
        handle.reply(id,json!({"error":{"status":409,"code":"field_conflict","message":"Changed","details":{"current":2}}}));
    } else {
        panic!("expected capability");
    }
    let output = finish(&events);
    assert_eq!(output["status"], 409);
    assert_eq!(output["body"]["error"]["details"]["current"], 2);
}

#[test]
fn public_http_errors_are_client_only_and_unexpected_failures_are_bounded() {
    let source = "export default {'GET /':()=>{throw new AnkoleRuntime.HttpError(422,'bad_value','Fix value',{field:'a'})}}";
    assert_eq!(
        run(source, "GET", "/")["body"]["error"]["details"]["field"],
        "a"
    );
    for source in [
        "export default {'GET /':()=>{throw Error('private failure')}}",
        "export default {'GET /':()=>{throw new AnkoleRuntime.HttpError(500,'forged')}}",
        "export default {'GET /':()=>1n}",
        "export default {'GET /':()=>{let x={};x.x=x;return x}}",
        "export default {'GET /':()=>()=>1}",
        "export default {'GET /':()=>({then(){throw Error('then failure')}})}",
    ] {
        let output = run(source, "GET", "/");
        assert_eq!(output["status"], 500, "{output}");
        assert_eq!(output["body"]["error"]["message"], "Applet handler failed");
        assert!(output["debug"]["message"].is_string());
    }
    assert_eq!(
        run("export default {'GET /':()=>undefined}", "GET", "/")["status"],
        204
    );
}

#[test]
fn console_and_file_bytes_use_the_live_bridge() {
    let source = "export default {'POST /':async()=>{console.info('reading',1); const f=await AnkoleRuntime.file.read('pages/p/x'); console.log(f.bytes instanceof Uint8Array); return AnkoleRuntime.file.write('p',{name:'x',bytes:f.bytes})}}";
    let (handle, events) = launch(source, context("POST", "/"), false, 2000, 32);
    if let Event::Call { id, operation, .. } = events.recv_timeout(Duration::from_secs(5)).unwrap()
    {
        assert_eq!(operation, "file.read");
        handle.reply(id, json!({"value":{"bytes":{"__ankole_bytes":"AAH/"}}}));
    } else {
        panic!("expected read")
    }
    if let Event::Call {
        id,
        operation,
        arguments,
    } = events.recv_timeout(Duration::from_secs(5)).unwrap()
    {
        assert_eq!(operation, "file.write");
        assert_eq!(arguments[1]["bytes"]["__ankole_bytes"], "AAH/");
        handle.reply(id, json!({"value":{"path":"pages/p/x"}}));
    } else {
        panic!("expected write")
    }
    let output = finish(&events);
    assert_eq!(output["body"]["path"], "pages/p/x");
    assert_eq!(output["logs"][0]["message"], "reading 1");
    assert_eq!(output["logs"][1]["message"], "true");
}

#[test]
fn timeout_covers_javascript_and_unresolved_waits() {
    for source in [
        "export default {'GET /':()=>{while(true){}}}",
        "export default {'GET /':()=>new Promise(()=>{})}",
    ] {
        let (_handle, events) = launch(source, context("GET", "/"), false, 50, 32);
        let output = finish(&events);
        assert_eq!(
            output["body"]["error"]["code"], "handler_timeout",
            "{output}"
        );
    }
    let (_handle, events) = launch(
        "export default {'GET /':()=>AnkoleRuntime.db.query('t',{})}",
        context("GET", "/"),
        false,
        50,
        32,
    );
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(5)).unwrap(),
        Event::Call { .. }
    ));
    assert_eq!(finish(&events)["body"]["error"]["code"], "handler_timeout");
}

#[test]
fn cancellation_interrupts_compute_and_capability_waits() {
    for source in [
        "export default {'GET /':()=>{while(true){}}}",
        "export default {'GET /':()=>AnkoleRuntime.db.query('t',{})}",
    ] {
        let (handle, events) = launch(source, context("GET", "/"), false, 2000, 32);
        std::thread::sleep(Duration::from_millis(30));
        handle.cancel();
        let output = loop {
            match events.recv_timeout(Duration::from_secs(5)).unwrap() {
                Event::Done(value) => break value,
                Event::Call { .. } => {}
            }
        };
        assert_eq!(output["body"]["error"]["code"], "handler_cancelled");
    }
}

#[test]
fn memory_pressure_is_confined_to_the_invocation() {
    if std::env::var_os("ANKOLE_APPLET_MEMORY_CHILD").is_some() {
        for source in [
            "export default {'GET /':()=>new Uint8Array(256*1024*1024)}",
            "export default {'GET /':()=>new SharedArrayBuffer(256*1024*1024)}",
            "export default {'GET /':()=>{while(true)console.log('repeated log')}}",
            "export default {'GET /':()=>{const xs=[];while(true){xs.push(new Uint8Array(1024*1024))}}}",
            "export default {'GET /':()=>{const xs=[];while(true){xs.push(Array(10000).fill('hello'))}}}",
            "export default {'GET /':()=>{const xs=[];while(true){xs.push(Array(10000).fill('hello'),new Uint8Array(1024*1024))}}}",
        ] {
            let (_handle, events) = launch(source, context("GET", "/"), false, 3000, 16);
            let output = finish(&events);
            assert_eq!(
                output["body"]["error"]["code"], "handler_out_of_memory",
                "{output}"
            );
            assert_eq!(
                run("export default {'GET /':()=>42}", "GET", "/")["body"],
                42
            );
        }
        for heap in [1, 2, 4] {
            let (_handle, events) = launch(
                "export default {'GET /':()=>42}",
                context("GET", "/"),
                false,
                2000,
                heap,
            );
            let output = finish(&events);
            assert!(
                output["status"] == 200
                    || output["body"]["error"]["code"] == "handler_out_of_memory",
                "{output}"
            );
        }
        return;
    }
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .arg("applet_runtime::tests::memory_pressure_is_confined_to_the_invocation")
        .arg("--exact")
        .arg("--nocapture")
        .env("ANKOLE_APPLET_MEMORY_CHILD", "1")
        .status()
        .unwrap();
    assert!(
        status.success(),
        "native memory tests must not abort their host process"
    );
}

#[test]
fn getter_proxy_and_non_enumerable_routes_are_captured_once() {
    for source in [
        "let n=0;export default {get 'GET /'(){n++;return ()=>n}}",
        "let n=0;export default new Proxy({'GET /':()=>n},{get(t,k){n++;return t[k]}})",
        "const routes={};Object.defineProperty(routes,'GET /',{value:()=>1});export default routes",
    ] {
        assert_eq!(run(source, "GET", "/")["body"], 1);
    }
    for source in [
        "export default {get 'GET /'(){AnkoleRuntime.file.list('p').catch(()=>{});return ()=>1}}",
        "export default new Proxy({'GET /':()=>1},{ownKeys(t){AnkoleRuntime.db.query('t',{}).catch(()=>{});return Reflect.ownKeys(t)}})",
    ] {
        let (_handle, events) = launch(source, Value::Null, true, 2000, 32);
        assert_eq!(finish(&events)["status"], 400);
    }
}
#[test]
fn unicode_literal_and_parameter_segments_decode_once() {
    let source = "export default {'GET /你好/café':()=>1,'GET /hello world':()=>2,'GET /a+b':()=>3,'GET /:订单号':({params})=>params}";
    assert_eq!(
        run(source, "GET", "/%E4%BD%A0%E5%A5%BD/caf%C3%A9")["body"],
        1
    );
    assert_eq!(run(source, "GET", "/hello%20world")["body"], 2);
    assert_eq!(run(source, "GET", "/a+b")["body"], 3);
    assert_eq!(run(source, "GET", "/a%2Fb")["body"]["订单号"], "a/b");
    assert_eq!(run(source, "GET", "/%ZZ")["status"], 400);
}
#[test]
fn http_error_status_cannot_be_changed_after_construction() {
    let output = run(
        "export default {'GET /':()=>{const e=new AnkoleRuntime.HttpError(400,'bad');try{e.status=503;e.code='forged'}catch{}throw e}}",
        "GET",
        "/",
    );
    assert_eq!(output["status"], 400);
    assert_eq!(output["body"]["error"]["code"], "bad");
}

#[test]
fn prototype_mutation_cannot_forge_response_status_or_http_error_status() {
    let source = "Object.prototype.toJSON=()=>({status:503});Number.isInteger=()=>true;export default {'GET /':()=>{throw new AnkoleRuntime.HttpError(NaN,'bad')}}";
    assert_eq!(run(source, "GET", "/")["status"], 500);
    let source =
        "Object.prototype.toJSON=()=>({status:503});export default {'GET /':()=>undefined}";
    assert_eq!(run(source, "GET", "/")["status"], 204);
    let source = "Object.prototype.toJSON=()=>({status:503});export default {'GET /':()=>{throw new AnkoleRuntime.HttpError(400,'bad')}}";
    assert_eq!(run(source, "GET", "/")["status"], 400);
}
#[test]
fn cyclic_capability_arguments_fail_without_entering_native_recursive_conversion() {
    let source =
        "export default {'POST /':()=>{const x={};x.x=x;return AnkoleRuntime.db.query('t',x)}}";
    assert_eq!(
        run(source, "POST", "/")["body"]["error"]["code"],
        "handler_error"
    );
}

#[test]
fn capability_errors_are_http_errors_and_query_defaults_to_empty() {
    let source = "export default {'GET /':async()=>{try{return await AnkoleRuntime.db.query('t')}catch(e){return {isHttp:e instanceof AnkoleRuntime.HttpError,code:e.code,status:e.status}}}}";
    let (handle, events) = launch(source, context("GET", "/"), false, 2000, 32);
    match events.recv_timeout(Duration::from_secs(5)).unwrap() {
        Event::Call { id, arguments, .. } => {
            assert_eq!(arguments, json!(["t", {}]));
            handle.reply(
                id,
                json!({"error":{"status":403,"code":"forbidden","message":"No access"}}),
            );
        }
        event => panic!("{event:?}"),
    }
    assert_eq!(
        finish(&events)["body"],
        json!({"isHttp":true,"code":"forbidden","status":403})
    );
}

#[test]
fn pending_capabilities_share_the_same_memory_budget() {
    let (_handle, events) = launch(
        "export default {'GET /':()=>{const s='x'.repeat(1024*1024);while(true)void AnkoleRuntime.db.query('t',{s})}}",
        context("GET", "/"),
        false,
        2000,
        16,
    );
    let mut calls = 0;
    let output = loop {
        match events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Call { .. } => calls += 1,
            Event::Done(value) => break value,
        }
    };
    assert!(calls > 0);
    assert_eq!(output["body"]["error"]["code"], "handler_out_of_memory");
}

#[test]
fn transport_decoders_run_on_the_same_invocation_thread() {
    let (decoded, decoded_events) = mpsc::channel();
    let (handle, events) = launch_with(move || {
        decoded
            .send((
                "request",
                std::thread::current().id(),
                std::thread::current().name().map(str::to_owned),
            ))
            .unwrap();
        Ok(Request {
            source: "export default {'GET /':()=>AnkoleRuntime.db.query('t')}".into(),
            context: context("GET", "/"),
            inspect: false,
            timeout_ms: 2000,
            heap_mb: 32,
        })
    });
    let (_, request_thread, name) = decoded_events.recv_timeout(Duration::from_secs(2)).unwrap();
    assert_eq!(name.as_deref(), Some("ankole-applet"));
    let call_id = match events.recv_timeout(Duration::from_secs(2)).unwrap() {
        Event::Call { id, .. } => id,
        event => panic!("{event:?}"),
    };
    let (decoded, reply_decoded) = mpsc::channel();
    assert!(handle.reply_with(call_id, move || {
        decoded.send(std::thread::current().id()).unwrap();
        Ok(json!({"value":{"ok":true}}))
    }));
    assert_eq!(
        reply_decoded.recv_timeout(Duration::from_secs(2)).unwrap(),
        request_thread
    );
    assert_eq!(finish(&events)["body"], json!({"ok":true}));
}

#[test]
fn request_decode_time_counts_against_the_original_deadline() {
    let (_handle, events) = launch_with(move || {
        std::thread::sleep(Duration::from_millis(50));
        Ok(Request {
            source: "export default {'GET /':()=>42}".into(),
            context: context("GET", "/"),
            inspect: false,
            timeout_ms: 20,
            heap_mb: 32,
        })
    });
    assert_eq!(finish(&events)["body"]["error"]["code"], "handler_timeout");
}

#[test]
fn cancellation_remains_effective_before_and_after_transport_decode() {
    let (decoding, decoder_started) = mpsc::channel();
    let (release, decoder_release) = mpsc::channel();
    let (handle, events) = launch_with(move || {
        decoding.send(()).unwrap();
        decoder_release.recv().unwrap();
        Ok(Request {
            source: "export default {'GET /':()=>AnkoleRuntime.db.query('t')}".into(),
            context: context("GET", "/"),
            inspect: false,
            timeout_ms: 2000,
            heap_mb: 32,
        })
    });
    decoder_started
        .recv_timeout(Duration::from_secs(2))
        .unwrap();
    handle.cancel();
    release.send(()).unwrap();
    assert_eq!(
        finish(&events)["body"]["error"]["code"],
        "handler_cancelled"
    );

    let (handle, events) = launch(
        "export default {'POST /':async()=>{await AnkoleRuntime.db.query('t');await AnkoleRuntime.db.write('t',{});return 1}}",
        context("POST", "/"),
        false,
        2000,
        32,
    );
    let call_id = match events.recv_timeout(Duration::from_secs(2)).unwrap() {
        Event::Call { id, .. } => id,
        event => panic!("{event:?}"),
    };
    let (decoding, decoder_started) = mpsc::channel();
    let (release, decoder_release) = mpsc::channel();
    assert!(handle.reply_with(call_id, move || {
        decoding.send(()).unwrap();
        decoder_release.recv().unwrap();
        Ok(json!({"value":{}}))
    }));
    decoder_started
        .recv_timeout(Duration::from_secs(2))
        .unwrap();
    handle.cancel();
    release.send(()).unwrap();
    assert_eq!(
        finish(&events)["body"]["error"]["code"],
        "handler_cancelled"
    );
}

#[test]
fn invalid_transport_reply_rejects_the_capability_instead_of_stalling() {
    let (handle, events) = launch(
        "export default {'GET /':()=>AnkoleRuntime.db.query('t')}",
        context("GET", "/"),
        false,
        2000,
        32,
    );
    let call_id = match events.recv_timeout(Duration::from_secs(2)).unwrap() {
        Event::Call { id, .. } => id,
        event => panic!("{event:?}"),
    };
    assert!(handle.reply_with(call_id, || Err("invalid JSON".into())));
    assert_eq!(finish(&events)["body"]["error"]["code"], "handler_error");
}

#[test]
fn native_admission_rejects_overload_and_releases_slots_after_cancel() {
    // Run this capacity assertion with no other Applet test occupying slots.
    // Acquire the real permits rather than changing their production limit.
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut permits = Vec::new();
    while permits.len() < MAX_CONCURRENT_RUNS - 1 {
        if let Some(permit) = RunPermit::acquire() {
            permits.push(permit);
        } else {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    let (handle, active) = launch(
        "export default {'GET /':()=>AnkoleRuntime.db.schema('waiting')}",
        context("GET", "/"),
        false,
        5_000,
        32,
    );
    assert!(matches!(
        active.recv_timeout(Duration::from_secs(5)).unwrap(),
        Event::Call { .. }
    ));
    let (sender, receiver) = mpsc::channel();
    start(
        Request {
            source: String::new(),
            inspect: true,
            context: Value::Null,
            timeout_ms: 100,
            heap_mb: 32,
        },
        Arc::new(move |event| {
            sender.send(event).unwrap();
        }),
    )
    .unwrap();
    assert_eq!(finish(&receiver)["status"], 503);
    handle.cancel();
    assert_eq!(
        finish(&active)["body"]["error"]["code"],
        "handler_cancelled"
    );
    drop(permits);
    assert_eq!(
        run("export default {'GET /':()=>42}", "GET", "/")["body"],
        42
    );
}
