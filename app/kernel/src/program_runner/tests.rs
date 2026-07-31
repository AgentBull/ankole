use super::*;
use serde_json::json;

fn run_program(program: &str, tools: &[&str], memo: Vec<MemoEntry>) -> RunOutcome {
    run(RunRequest {
        program: program.to_string(),
        tools: tools.iter().map(ToString::to_string).collect(),
        memo,
        timeout_ms: Some(5_000),
        heap_limit_bytes: None,
    })
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
            name: "market".to_string(),
            arguments: json!({"symbol": "600519"})
        }]
    );
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
            name: "news".to_string(),
            arguments: json!({"topic": 1700})
        }]
    );
}

#[test]
fn completes_after_full_memo_replay() {
    let memo = vec![MemoEntry {
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
fn divergent_replay_fails_loudly() {
    let memo = vec![MemoEntry {
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
fn runaway_programs_hit_the_timeout() {
    let outcome = run(RunRequest {
        program: "for (;;) {}".to_string(),
        tools: Vec::new(),
        memo: Vec::new(),
        timeout_ms: Some(500),
        heap_limit_bytes: None,
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
    });

    assert_eq!(outcome.status, "failed");
    assert!(
        outcome
            .error
            .as_deref()
            .is_some_and(|error| error.contains("execution terminated"))
    );
}

#[test]
fn run_json_round_trips() {
    let outcome_json = run_json(
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
