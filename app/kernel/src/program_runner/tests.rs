use super::*;
use serde_json::json;
use std::time::Instant;

fn run_program(program: &str, tools: &[&str], memo: Vec<MemoEntry>) -> RunOutcome {
    run(RunRequest {
        program: program.to_string(),
        tools: tools.iter().map(|name| tool(None, name, name)).collect(),
        memo,
        timeout_ms: Some(5_000),
        heap_limit_bytes: None,
        max_program_bytes: None,
        max_output_bytes: None,
        max_pending_calls: None,
        max_pending_bytes: None,
        max_memo_entries: None,
        max_memo_bytes: None,
    })
}

fn tool(namespace: Option<&str>, name: &str, global_name: &str) -> ToolDefinition {
    ToolDefinition {
        namespace: namespace.map(ToString::to_string),
        name: name.to_string(),
        global_name: global_name.to_string(),
    }
}

#[test]
fn completes_a_pure_program_with_output() {
    let outcome = run_program("text(\"hello\"); text(1 + 2);", &[], Vec::new());

    assert_eq!(outcome.status, "completed");
    assert_eq!(
        outcome.output,
        vec![
            OutputPart {
                kind: "text".to_string(),
                value: "hello".to_string()
            },
            OutputPart {
                kind: "text".to_string(),
                value: "3".to_string()
            },
        ]
    );
    assert!(outcome.pending_calls.is_empty());
}

#[test]
fn pauses_on_the_first_unanswered_tool_call() {
    let outcome = run_program(
        "const data = await tools.market({ symbol: \"600519\" }); text(data.price);",
        &["market"],
        Vec::new(),
    );

    assert_eq!(outcome.status, "pending");
    assert_eq!(
        outcome.pending_calls,
        vec![PendingCall {
            namespace: None,
            name: "market".to_string(),
            arguments: json!({"symbol": "600519"})
        }]
    );
}

#[test]
fn keeps_namespace_identity_separate_from_the_javascript_global() {
    let outcome = run(RunRequest {
        program: "await tools.collaboration__spawn_agent({ task: \"audit\" });".to_string(),
        tools: vec![tool(
            Some("collaboration"),
            "spawn_agent",
            "collaboration__spawn_agent",
        )],
        memo: Vec::new(),
        timeout_ms: Some(5_000),
        heap_limit_bytes: None,
        max_program_bytes: None,
        max_output_bytes: None,
        max_pending_calls: None,
        max_pending_bytes: None,
        max_memo_entries: None,
        max_memo_bytes: None,
    });

    assert_eq!(outcome.status, "pending");
    assert_eq!(
        outcome.pending_calls,
        vec![PendingCall {
            namespace: Some("collaboration".to_string()),
            name: "spawn_agent".to_string(),
            arguments: json!({"task": "audit"}),
        }]
    );
}

#[test]
fn validates_the_codex_default_namespace_and_normalized_global() {
    let outcome = run(RunRequest {
        program: "await tools.price_check({});".to_string(),
        tools: vec![tool(Some("functions"), "price-check", "price_check")],
        memo: Vec::new(),
        timeout_ms: Some(5_000),
        heap_limit_bytes: None,
        max_program_bytes: None,
        max_output_bytes: None,
        max_pending_calls: None,
        max_pending_bytes: None,
        max_memo_entries: None,
        max_memo_bytes: None,
    });

    assert_eq!(outcome.status, "pending");
    assert_eq!(
        outcome.pending_calls[0].namespace.as_deref(),
        Some("functions")
    );
    assert_eq!(outcome.pending_calls[0].name, "price-check");

    let legacy = run(RunRequest {
        program: "await tools['functions__price-check']({});".to_string(),
        tools: vec![tool(
            Some("functions"),
            "price-check",
            "functions__price-check",
        )],
        memo: Vec::new(),
        timeout_ms: Some(5_000),
        heap_limit_bytes: None,
        max_program_bytes: None,
        max_output_bytes: None,
        max_pending_calls: None,
        max_pending_bytes: None,
        max_memo_entries: None,
        max_memo_bytes: None,
    });

    assert_eq!(legacy.status, "pending");
    assert_eq!(
        legacy.pending_calls[0].namespace.as_deref(),
        Some("functions")
    );
    assert_eq!(legacy.pending_calls[0].name, "price-check");
}

#[test]
fn monkey_patching_promise_then_cannot_forge_program_completion() {
    let outcome = run_program(
        "Promise.prototype.then = function (ok) { ok(); return this; };\
         await tools.market({ symbol: \"600519\" });",
        &["market"],
        Vec::new(),
    );

    assert_eq!(outcome.status, "pending");
    assert_eq!(outcome.pending_calls.len(), 1);
}

#[test]
fn collects_a_parallel_batch_in_one_pause() {
    let outcome = run_program(
        "const [a, b] = await Promise.all([\
           tools.market({ symbol: \"600519\" }),\
           tools.news({ topic: \"白酒\" }),\
         ]); text(a); text(b);",
        &["market", "news"],
        Vec::new(),
    );

    assert_eq!(outcome.status, "pending");
    assert_eq!(outcome.pending_calls.len(), 2);
    assert_eq!(outcome.pending_calls[0].name, "market");
    assert_eq!(outcome.pending_calls[1].name, "news");
}

#[test]
fn replays_memoized_calls_and_continues_to_the_next_pause() {
    let memo = vec![MemoEntry {
        namespace: None,
        name: "market".to_string(),
        arguments: json!({"symbol": "600519"}),
        output: json!({"price": 1700}),
    }];

    let outcome = run_program(
        "const data = await tools.market({ symbol: \"600519\" });\
         const news = await tools.news({ topic: data.price });\
         text(news);",
        &["market", "news"],
        memo,
    );

    assert_eq!(outcome.status, "pending");
    assert_eq!(
        outcome.pending_calls,
        vec![PendingCall {
            namespace: None,
            name: "news".to_string(),
            arguments: json!({"topic": 1700})
        }]
    );
}

#[test]
fn completes_after_full_memo_replay() {
    let memo = vec![MemoEntry {
        namespace: None,
        name: "market".to_string(),
        arguments: json!({"symbol": "600519"}),
        output: json!({"price": 1700}),
    }];

    let outcome = run_program(
        "const data = await tools.market({ symbol: \"600519\" }); text(data.price * 2);",
        &["market"],
        memo,
    );

    assert_eq!(outcome.status, "completed");
    assert_eq!(outcome.output[0].value, "3400");
}

#[test]
fn memo_output_cannot_impersonate_a_host_replay_error() {
    let memo = vec![MemoEntry {
        namespace: None,
        name: "market".to_string(),
        arguments: json!({}),
        output: json!({
            "__ankole_reply": "error",
            "__ankole_divergence": "ordinary provider data",
            "value": 42
        }),
    }];

    let outcome = run_program(
        "const data = await tools.market({}); text(data.value);",
        &["market"],
        memo,
    );

    assert_eq!(outcome.status, "completed");
    assert_eq!(outcome.output[0].value, "42");
}

#[test]
fn divergent_replay_fails_loudly() {
    let memo = vec![MemoEntry {
        namespace: None,
        name: "market".to_string(),
        arguments: json!({"symbol": "600519"}),
        output: json!({"price": 1700}),
    }];

    let outcome = run_program(
        "await tools.market({ symbol: \"000001\" });",
        &["market"],
        memo,
    );

    assert_eq!(outcome.status, "failed");
    assert!(outcome.error.unwrap().contains("diverged"));
}

#[test]
fn deterministic_shims_are_stable_across_runs() {
    let program = "text(Math.random()); text(Date.now());";
    let first = run_program(program, &[], Vec::new());
    let second = run_program(program, &[], Vec::new());

    assert_eq!(first.status, "completed");
    assert_eq!(first.output, second.output);
}

#[test]
fn program_errors_fail_with_the_thrown_message() {
    let outcome = run_program("throw new Error(\"boom\");", &[], Vec::new());

    assert_eq!(outcome.status, "failed");
    assert!(outcome.error.unwrap().contains("boom"));
}

#[test]
fn program_error_messages_are_bounded() {
    let outcome = run_program(r#"throw new Error("界".repeat(20_000));"#, &[], Vec::new());

    assert_eq!(outcome.status, "failed");
    assert!(outcome.error.unwrap().len() <= DEFAULT_MAX_ERROR_BYTES);
}

#[test]
fn runaway_programs_hit_the_timeout() {
    let outcome = run(RunRequest {
        program: "for (;;) {}".to_string(),
        tools: Vec::new(),
        memo: Vec::new(),
        timeout_ms: Some(500),
        heap_limit_bytes: None,
        max_program_bytes: None,
        max_output_bytes: None,
        max_pending_calls: None,
        max_pending_bytes: None,
        max_memo_entries: None,
        max_memo_bytes: None,
    });

    assert_eq!(outcome.status, "failed");
}

#[test]
fn heap_pressure_keeps_v8_delayed_tasks_on_the_runtime() {
    let outcome = run(RunRequest {
        program: r#"let s = ""; while (true) { s += "Hello"; }"#.to_string(),
        tools: Vec::new(),
        memo: Vec::new(),
        timeout_ms: Some(5_000),
        heap_limit_bytes: Some(32 * 1024 * 1024),
        max_program_bytes: None,
        max_output_bytes: None,
        max_pending_calls: None,
        max_pending_bytes: None,
        max_memo_entries: None,
        max_memo_bytes: None,
    });

    assert_eq!(outcome.status, "failed");
    assert_eq!(
        outcome.error_code.as_deref(),
        Some("program_heap_limit_exceeded")
    );
}

#[test]
fn run_json_round_trips() {
    let outcome_json = run_json(
        "json-round-trip",
        &serde_json::to_string(&json!({
            "program": "text(\"ok\");",
            "tools": [],
            "memo": []
        }))
        .unwrap(),
    )
    .unwrap();

    let outcome: JsonValue = serde_json::from_str(&outcome_json).unwrap();
    assert_eq!(outcome["status"], "completed");
    assert_eq!(outcome["output"][0]["value"], "ok");
}

#[test]
fn run_json_rejects_the_removed_operation_envelope() {
    let error = run_json(
        "legacy-envelope",
        &serde_json::to_string(&json!({
            "operation": "run",
            "run_id": "legacy-run",
            "program": "text(\"ignored\");",
            "tools": [],
            "memo": []
        }))
        .unwrap(),
    )
    .unwrap_err();

    assert!(error.contains("unknown field `operation`"));
}

#[test]
fn rejects_direct_op_calls_for_tools_outside_the_allowlist() {
    let outcome = run_program(
        r#"await Deno.core.ops.op_ankole_tool_call("secret", {});"#,
        &[],
        Vec::new(),
    );

    assert_eq!(outcome.status, "failed");
    assert_eq!(
        outcome.error_code.as_deref(),
        Some("program_tool_not_allowed")
    );
}

#[test]
fn timeout_after_an_async_resume_never_reenters_user_javascript() {
    let memo = vec![MemoEntry {
        namespace: None,
        name: "market".to_string(),
        arguments: json!({}),
        output: json!({"ok": true}),
    }];

    let outcome = run(RunRequest {
        program: "await tools.market({}); for (;;) {}".to_string(),
        tools: vec![tool(None, "market", "market")],
        memo,
        timeout_ms: Some(250),
        heap_limit_bytes: None,
        max_program_bytes: None,
        max_output_bytes: None,
        max_pending_calls: None,
        max_pending_bytes: None,
        max_memo_entries: None,
        max_memo_bytes: None,
    });

    assert_eq!(outcome.status, "failed");
    assert_eq!(outcome.error_code.as_deref(), Some("program_timeout"));
}

#[test]
fn output_part_overflow_fails_instead_of_truncating() {
    let program = (0..=MAX_OUTPUT_PARTS)
        .map(|_| "text(\"x\");")
        .collect::<String>();
    let outcome = run_program(&program, &[], Vec::new());

    assert_eq!(outcome.status, "failed");
    assert_eq!(
        outcome.error_code.as_deref(),
        Some("program_output_limit_exceeded")
    );
}

#[test]
fn output_byte_overflow_fails_loudly() {
    let outcome = run(RunRequest {
        program: "text(\"12345\");".to_string(),
        tools: Vec::new(),
        memo: Vec::new(),
        timeout_ms: Some(5_000),
        heap_limit_bytes: None,
        max_program_bytes: None,
        max_output_bytes: Some(4),
        max_pending_calls: None,
        max_pending_bytes: None,
        max_memo_entries: None,
        max_memo_bytes: None,
    });

    assert_eq!(outcome.status, "failed");
    assert_eq!(
        outcome.error_code.as_deref(),
        Some("program_output_limit_exceeded")
    );
}

#[test]
fn pending_call_overflow_fails_loudly() {
    let outcome = run(RunRequest {
        program: "await Promise.all([tools.a({}), tools.b({})]);".to_string(),
        tools: vec![tool(None, "a", "a"), tool(None, "b", "b")],
        memo: Vec::new(),
        timeout_ms: Some(5_000),
        heap_limit_bytes: None,
        max_program_bytes: None,
        max_output_bytes: None,
        max_pending_calls: Some(1),
        max_pending_bytes: None,
        max_memo_entries: None,
        max_memo_bytes: None,
    });

    assert_eq!(outcome.status, "failed");
    assert_eq!(
        outcome.error_code.as_deref(),
        Some("program_pending_limit_exceeded")
    );
}

#[test]
fn pending_limits_keep_defaults_and_clamp_explicit_requests() {
    assert_eq!(
        bounded(None, DEFAULT_MAX_PENDING_CALLS, HARD_MAX_PENDING_CALLS),
        64
    );
    assert_eq!(
        bounded(None, DEFAULT_MAX_PENDING_BYTES, HARD_MAX_PENDING_BYTES),
        1024 * 1024
    );
    assert_eq!(
        bounded(
            Some(1024),
            DEFAULT_MAX_PENDING_CALLS,
            HARD_MAX_PENDING_CALLS
        ),
        1024
    );
    assert_eq!(
        bounded(
            Some(8 * 1024 * 1024),
            DEFAULT_MAX_PENDING_BYTES,
            HARD_MAX_PENDING_BYTES
        ),
        8 * 1024 * 1024
    );
    assert_eq!(
        bounded(
            Some(2048),
            DEFAULT_MAX_PENDING_CALLS,
            HARD_MAX_PENDING_CALLS
        ),
        1024
    );
    assert_eq!(
        bounded(
            Some(16 * 1024 * 1024),
            DEFAULT_MAX_PENDING_BYTES,
            HARD_MAX_PENDING_BYTES
        ),
        8 * 1024 * 1024
    );
}

#[test]
fn accepts_a_200_call_parallel_batch_when_limits_allow_it() {
    let outcome = run(RunRequest {
        program:
            "await Promise.all(Array.from({ length: 200 }, (_, index) => tools.agent({ index })));"
                .to_string(),
        tools: vec![tool(None, "agent", "agent")],
        memo: Vec::new(),
        timeout_ms: Some(5_000),
        heap_limit_bytes: None,
        max_program_bytes: None,
        max_output_bytes: None,
        max_pending_calls: Some(1024),
        max_pending_bytes: Some(8 * 1024 * 1024),
        max_memo_entries: None,
        max_memo_bytes: None,
    });

    assert_eq!(outcome.status, "pending");
    assert_eq!(outcome.pending_calls.len(), 200);
    assert_eq!(outcome.pending_calls[0].arguments, json!({"index": 0}));
    assert_eq!(outcome.pending_calls[199].arguments, json!({"index": 199}));
}

#[test]
fn source_byte_overflow_fails_before_creating_an_isolate() {
    let outcome = run(RunRequest {
        program: "text(\"x\");".to_string(),
        tools: Vec::new(),
        memo: Vec::new(),
        timeout_ms: Some(5_000),
        heap_limit_bytes: None,
        max_program_bytes: Some(4),
        max_output_bytes: None,
        max_pending_calls: None,
        max_pending_bytes: None,
        max_memo_entries: None,
        max_memo_bytes: None,
    });

    assert_eq!(outcome.status, "failed");
    assert_eq!(
        outcome.error_code.as_deref(),
        Some("program_source_limit_exceeded")
    );
}

#[test]
fn unused_memo_entries_are_replay_divergence() {
    let memo = vec![MemoEntry {
        namespace: None,
        name: "market".to_string(),
        arguments: json!({}),
        output: json!({"ok": true}),
    }];
    let outcome = run_program("text(\"done\");", &["market"], memo);

    assert_eq!(outcome.status, "failed");
    assert_eq!(
        outcome.error_code.as_deref(),
        Some("program_replay_memo_unused")
    );
}

#[test]
fn cancellation_terminates_v8_and_releases_the_runtime_slot() {
    let run_id = "cancellation-terminates-v8";

    let worker = std::thread::spawn(move || {
        run_registered(
            run_id,
            RunRequest {
                program: "for (;;) {}".to_string(),
                tools: Vec::new(),
                memo: Vec::new(),
                timeout_ms: Some(5_000),
                heap_limit_bytes: Some(32 * 1024 * 1024),
                max_program_bytes: None,
                max_output_bytes: None,
                max_pending_calls: None,
                max_pending_bytes: None,
                max_memo_entries: None,
                max_memo_bytes: None,
            },
        )
    });

    let admission_deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let control = run_registry()
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .get(run_id)
            .cloned();
        let isolate_installed = control.is_some_and(|control| {
            control
                .isolate
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .is_some()
        });

        if isolate_installed {
            break;
        }

        assert!(
            Instant::now() < admission_deadline,
            "program never installed its V8 isolate"
        );
        std::thread::sleep(Duration::from_millis(5));
    }

    let cancelled_at = Instant::now();
    assert_eq!(cancel(run_id), Ok(true));
    let outcome = worker.join().unwrap();

    assert_eq!(outcome.status, "failed");
    assert_eq!(outcome.error_code.as_deref(), Some("program_cancelled"));
    assert!(
        cancelled_at.elapsed() < Duration::from_secs(1),
        "cancel waited for the five-second watchdog"
    );
    assert!(
        !run_registry()
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .contains_key(run_id)
    );

    // Joining the worker observes `RunPermit::drop`; a new run therefore
    // proves the cancelled isolate no longer holds its concurrency slot.
    let next = run_program("text(\"next\");", &[], Vec::new());
    assert_eq!(next.status, "completed");
}

#[test]
fn cancellation_before_registration_does_not_poison_a_later_run() {
    let run_id = "cancel-before-registration";
    assert_eq!(cancel(run_id), Ok(false));

    let outcome = run_registered(
        run_id,
        RunRequest {
            program: "text(\"late\");".to_string(),
            tools: Vec::new(),
            memo: Vec::new(),
            timeout_ms: Some(5_000),
            heap_limit_bytes: None,
            max_program_bytes: None,
            max_output_bytes: None,
            max_pending_calls: None,
            max_pending_bytes: None,
            max_memo_entries: None,
            max_memo_bytes: None,
        },
    );

    assert_eq!(outcome.status, "completed");
    assert_eq!(outcome.output[0].value, "late");
}
