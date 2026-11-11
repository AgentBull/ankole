use super::super::*;

fn resolver(model: &str) -> APIResolver {
    APIResolver::new(
        APIResolverKind::CloudflareDecision,
        ResponseContext {
            model: model.to_string(),
            request: json!({
                "model": "decision.default",
                "state": null,
                "questions": {"urgent": {"type": "noul", "instructions": "Is it urgent?"}}
            }),
            provider_options: json!({}),
            stream: None,
            include_model: false,
            ..ResponseContext::default()
        },
    )
}

#[test]
fn workers_ai_decision_models_take_top_level_fields_and_a_short_model_id() {
    let body = Value::Object(resolver("@cf/cloudflare/clef-flash").build_body().unwrap());

    assert_eq!(
        body,
        json!({
            "model": "clef-flash",
            "state": null,
            "questions": {"urgent": {"type": "noul", "instructions": "Is it urgent?"}}
        })
    );
}

#[test]
fn partner_decision_models_take_fields_inside_input() {
    let body = Value::Object(resolver("typesafe/jev").build_body().unwrap());

    assert_eq!(
        body,
        json!({
            "model": "typesafe/jev",
            "input": {
                "state": null,
                "questions": {"urgent": {"type": "noul", "instructions": "Is it urgent?"}}
            }
        })
    );
}

#[test]
fn decision_response_is_read_from_the_result_envelope() {
    let answers = json!({"urgent": {"type": "noul", "noul": 0.93}});
    let usage = json!({"input_tokens": 41, "output_tokens": 0});

    let body = resolver("typesafe/jev")
        .normalize_body(
            200,
            json!({
                "state": "Completed",
                "result": {"model": "jev-1.13.0", "answers": answers, "usage": usage}
            }),
        )
        .unwrap();

    assert_eq!(
        body,
        json!({"model": "jev-1.13.0", "answers": answers, "usage": usage})
    );
}

#[test]
fn decision_response_without_answers_is_an_invalid_upstream_response() {
    let error = resolver("@cf/cloudflare/clef")
        .normalize_body(200, json!({"result": {"model": "clef"}}))
        .unwrap_err();

    assert_eq!(error.code, "invalid_upstream_response");
}
