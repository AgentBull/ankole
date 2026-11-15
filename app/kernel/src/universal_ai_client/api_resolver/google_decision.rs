use super::decision::KNOWN_DECISION_FIELDS;
use super::*;

const GOOGLE_DECISION_MAX_QUESTION_KEY_LEN: usize = 64;

#[derive(Debug)]
pub(super) struct GoogleDecision;

impl APIProtocol for GoogleDecision {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        let strict = context.policy() == ConversionPolicy::Strict;
        let mut request = context.canonical_request_object();
        strip_non_streaming_flag(&mut request, strict, "Google decision")?;
        validate_known_request_fields(&request, KNOWN_DECISION_FIELDS, strict, "Google decision")?;

        let state = request.remove("state").unwrap_or(Value::Null);
        let images = request.remove("images").unwrap_or(Value::Null);
        let questions = request.remove("questions").unwrap_or(Value::Null);
        let mut body = context.sanitized_provider_options_object();
        for (key, value) in request {
            body.insert(key, value);
        }
        if context.include_model {
            body.insert(
                "model".to_string(),
                json!(google_decision_model_name(&context.model)),
            );
        } else {
            body.remove("model");
        }
        body.insert("input".to_string(), google_decision_input(state, images)?);
        body.insert(
            "questions".to_string(),
            google_decision_questions(&questions)?,
        );
        Ok(body)
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        let payload = provider_object_body(status, body, "Google decision")?;

        if let Some(feedback) = payload.get("prompt_feedback").and_then(Value::as_object)
            && let Some(block_reason) = feedback
                .get("block_reason")
                .and_then(Value::as_str)
                .filter(|reason| !reason.is_empty())
        {
            let message = feedback
                .get("block_reason_message")
                .and_then(Value::as_str)
                .filter(|msg| !msg.is_empty())
                .map(str::to_string)
                .unwrap_or_else(|| {
                    format!("Google decision model blocked the request ({block_reason})")
                });
            return Err(
                StreamError::new("upstream_decision_refusal", "api_resolver", message)
                    .provider_status(status)
                    .provider_error_type(block_reason)
                    .provider_body_excerpt(sonic_rs::to_vec(&payload).unwrap_or_default()),
            );
        }

        let answers = payload
            .get("answers")
            .and_then(Value::as_object)
            .ok_or_else(|| {
                invalid_upstream_body_error(
                    status,
                    payload.clone(),
                    "Google decision response did not contain an answers object",
                )
            })?;
        let requested_questions = context.request.get("questions").and_then(Value::as_object);
        let wire_to_caller = requested_questions.map(|questions| {
            google_question_key_map(questions)
                .into_iter()
                .map(|(caller, wire)| (wire, caller))
                .collect::<BTreeMap<_, _>>()
        });
        let mut normalized = Map::new();

        for (wire_name, answer) in answers {
            let (caller_name, requested_question) =
                match (requested_questions, wire_to_caller.as_ref()) {
                    (Some(questions), Some(key_map)) => {
                        let caller_name = key_map.get(wire_name).ok_or_else(|| {
                            invalid_upstream_body_error(
                                status,
                                payload.clone(),
                                format!(
                                    "Google decision response answered unknown question {wire_name}"
                                ),
                            )
                        })?;
                        (caller_name.as_str(), questions.get(caller_name))
                    }
                    _unrequested => (wire_name.as_str(), None),
                };

            let normalized_answer = normalize_google_decision_answer(answer, requested_question)
                .ok_or_else(|| {
                    invalid_upstream_body_error(
                        status,
                        payload.clone(),
                        format!("Google decision answer for {caller_name} had an invalid shape"),
                    )
                })?;
            normalized.insert(caller_name.to_string(), normalized_answer);
        }

        if let Some(questions) = requested_questions
            && (normalized.len() != questions.len()
                || questions.keys().any(|name| !normalized.contains_key(name)))
        {
            return Err(invalid_upstream_body_error(
                status,
                payload.clone(),
                "Google decision response did not answer every question",
            ));
        }

        let default_model = google_decision_model_name(&context.model);
        let model = payload
            .get("model")
            .and_then(Value::as_str)
            .or_else(|| payload.get("modelVersion").and_then(Value::as_str))
            .unwrap_or(default_model);

        Ok(json!({
            "model": model,
            "answers": normalized,
            "usage": normalize_google_decision_usage(payload.get("usage"))
        }))
    }
}

fn google_decision_model_name(model: &str) -> &str {
    model.strip_prefix("models/").unwrap_or(model)
}

fn google_decision_input(state: Value, images: Value) -> Result<Value, StreamError> {
    let images = match images {
        Value::Null => Vec::new(),
        Value::Array(images) => images,
        _images => {
            return Err(StreamError::new(
                "invalid_decision_request",
                "api_resolver",
                "Google decision images must be an array",
            ));
        }
    };

    if images.is_empty() {
        return match state {
            Value::String(text) if !text.is_empty() => Ok(Value::String(text)),
            other => Ok(json!([{"type": "text", "text": google_decision_state_text(&other)?}])),
        };
    }

    let mut content = Vec::with_capacity(images.len() + 1);
    content.push(json!({"type": "text", "text": google_decision_state_text(&state)?}));
    for image in &images {
        let (mime_type, data_base64) = google_decision_image(image).ok_or_else(|| {
            StreamError::new(
                "invalid_decision_request",
                "api_resolver",
                "Google decision images must be PNG, JPEG, or WebP base64 data URLs",
            )
        })?;
        content.push(json!({"type": "image", "mime_type": mime_type, "data": data_base64}));
    }

    Ok(Value::Array(content))
}

fn google_decision_state_text(state: &Value) -> Result<String, StreamError> {
    match state {
        Value::String(text) if !text.is_empty() => Ok(text.clone()),
        _value => sonic_rs::to_string(state).map_err(|reason| {
            StreamError::new(
                "request_encode_failed",
                "api_resolver",
                format!("Google decision state could not be encoded as JSON: {reason}"),
            )
        }),
    }
}

fn google_decision_image(image: &Value) -> Option<(&'static str, &str)> {
    let rest = image.as_str()?.strip_prefix("data:")?;
    let (media_type, data_base64) = rest.split_once(";base64,")?;
    let mime_type = match media_type {
        "image/png" => "image/png",
        "image/jpeg" => "image/jpeg",
        "image/webp" => "image/webp",
        _media_type => return None,
    };
    (!data_base64.is_empty()).then_some((mime_type, data_base64))
}

fn is_google_question_key(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= GOOGLE_DECISION_MAX_QUESTION_KEY_LEN
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

fn google_question_key_map(questions: &Map<String, Value>) -> Vec<(String, String)> {
    let mut caller_names = questions.keys().cloned().collect::<Vec<_>>();
    caller_names.sort();

    let mut used = caller_names
        .iter()
        .filter(|name| is_google_question_key(name))
        .cloned()
        .collect::<BTreeSet<_>>();
    let mut next_alias = 1usize;
    let mut pairs = Vec::with_capacity(caller_names.len());

    for caller_name in caller_names {
        if is_google_question_key(&caller_name) {
            pairs.push((caller_name.clone(), caller_name));
            continue;
        }

        let wire_name = loop {
            let candidate = format!("ankole_q_{next_alias}");
            next_alias += 1;
            if used.insert(candidate.clone()) {
                break candidate;
            }
        };
        pairs.push((caller_name, wire_name));
    }

    pairs
}

fn google_decision_questions(questions: &Value) -> Result<Value, StreamError> {
    let questions = questions.as_object().ok_or_else(|| {
        StreamError::new(
            "invalid_decision_request",
            "api_resolver",
            "Google decision questions must be an object",
        )
    })?;
    let mut converted = Map::new();

    for (caller_name, wire_name) in google_question_key_map(questions) {
        let question = &questions[&caller_name];
        let question_type = question
            .get("type")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                StreamError::new(
                    "invalid_decision_request",
                    "api_resolver",
                    format!("Google decision question {caller_name} did not contain a type"),
                )
            })?;
        let instructions =
            google_decision_text(question.get("instructions").unwrap_or(&Value::Null))?;
        let mut result = Map::new();
        result.insert("type".to_string(), json!(question_type));
        result.insert("instructions".to_string(), Value::String(instructions));

        match question_type {
            "noul" => {
                if let Some(criteria) = question.get("criteria").and_then(Value::as_object) {
                    let mut mapped_criteria = Map::new();
                    if let Some(true_desc) = criteria.get("true")
                        && !true_desc.is_null()
                    {
                        mapped_criteria.insert(
                            "true_description".to_string(),
                            Value::String(google_decision_text(true_desc)?),
                        );
                    }
                    if let Some(false_desc) = criteria.get("false")
                        && !false_desc.is_null()
                    {
                        mapped_criteria.insert(
                            "false_description".to_string(),
                            Value::String(google_decision_text(false_desc)?),
                        );
                    }
                    if !mapped_criteria.is_empty() {
                        result.insert("criteria".to_string(), Value::Object(mapped_criteria));
                    }
                }
            }
            "choice" => {
                let criteria = question
                    .get("criteria")
                    .and_then(Value::as_object)
                    .ok_or_else(|| {
                        invalid_google_question(&caller_name, "choice criteria must be an object")
                    })?;
                let mut mapped_criteria = Map::new();
                for (option, description) in criteria {
                    let text = if description.is_null() {
                        String::new()
                    } else {
                        google_decision_text(description)?
                    };
                    mapped_criteria.insert(option.clone(), Value::String(text));
                }
                result.insert("criteria".to_string(), Value::Object(mapped_criteria));
            }
            "score" => {
                let criteria = question
                    .get("criteria")
                    .and_then(Value::as_array)
                    .ok_or_else(|| {
                        invalid_google_question(&caller_name, "score criteria must be an array")
                    })?;
                let mut levels = Vec::with_capacity(criteria.len());
                for criterion in criteria {
                    levels.push(Value::String(google_decision_text(criterion)?));
                }
                result.insert("criteria".to_string(), Value::Array(levels));
            }
            _question_type => {
                return Err(invalid_google_question(
                    &caller_name,
                    "unsupported question type",
                ));
            }
        }

        converted.insert(wire_name, Value::Object(result));
    }

    Ok(Value::Object(converted))
}

fn invalid_google_question(name: &str, message: &str) -> StreamError {
    StreamError::new(
        "invalid_decision_request",
        "api_resolver",
        format!("Google decision question {name}: {message}"),
    )
}

fn google_decision_text(value: &Value) -> Result<String, StreamError> {
    match value {
        Value::String(text) => Ok(text.clone()),
        _value => sonic_rs::to_string(value).map_err(|reason| {
            StreamError::new(
                "request_encode_failed",
                "api_resolver",
                format!("Google decision text could not be encoded as JSON: {reason}"),
            )
        }),
    }
}

fn normalize_google_decision_answer(
    answer: &Value,
    requested_question: Option<&Value>,
) -> Option<Value> {
    let requested_type = requested_question
        .and_then(|question| question.get("type"))
        .and_then(Value::as_str);

    match answer.get("type").and_then(Value::as_str)? {
        "noul" => {
            if requested_type.is_some_and(|kind| kind != "noul") {
                return None;
            }
            Some(json!({
                "type": "noul",
                "noul": answer.get("noul").filter(|value| value.is_number())?
            }))
        }
        "choice" => {
            if requested_type.is_some_and(|kind| kind != "choice") {
                return None;
            }
            let choice = answer.get("choice")?.as_str().filter(|s| !s.is_empty())?;
            let criteria = requested_question
                .and_then(|question| question.get("criteria"))
                .and_then(Value::as_object);
            if let Some(criteria) = criteria
                && !criteria.contains_key(choice)
            {
                return None;
            }

            let mut probabilities = Map::new();
            for (option, probability) in answer.get("probabilities")?.as_object()? {
                if option.is_empty() || !probability.is_number() {
                    return None;
                }
                if let Some(criteria) = criteria
                    && !criteria.contains_key(option)
                {
                    return None;
                }
                probabilities.insert(option.clone(), probability.clone());
            }

            Some(json!({
                "type": "choice",
                "choice": choice,
                "probabilities": probabilities,
                "confidence": answer.get("confidence").filter(|value| value.is_number())?
            }))
        }
        "score" => {
            if requested_type.is_some_and(|kind| kind != "score") {
                return None;
            }
            let criteria = requested_question
                .and_then(|question| question.get("criteria"))
                .and_then(Value::as_array);
            let mut probabilities = Map::new();
            for (level, probability) in answer.get("probabilities")?.as_object()? {
                let index = level.parse::<usize>().ok()?;
                if index.to_string() != *level || !probability.is_number() {
                    return None;
                }
                if let Some(items) = criteria
                    && index >= items.len()
                {
                    return None;
                }
                probabilities.insert(level.clone(), probability.clone());
            }

            let legend = match criteria {
                Some(items) => items
                    .iter()
                    .enumerate()
                    .map(|(index, item)| (index.to_string(), item.clone()))
                    .collect::<Map<_, _>>(),
                None => answer.get("legend")?.as_object()?.clone(),
            };

            Some(json!({
                "type": "score",
                "score": answer.get("score").filter(|value| value.is_number())?,
                "legend": legend,
                "probabilities": probabilities,
                "confidence": answer.get("confidence").filter(|value| value.is_number())?
            }))
        }
        _answer_type => None,
    }
}

fn normalize_google_decision_usage(usage: Option<&Value>) -> Value {
    let Some(object) = usage.and_then(Value::as_object) else {
        return json!({});
    };
    let mut normalized = object.clone();

    let total_input = normalized
        .remove("total_input_tokens")
        .filter(|value| value.as_u64().is_some());
    let total_output = normalized
        .remove("total_output_tokens")
        .filter(|value| value.as_u64().is_some());
    let total_cached = normalized
        .remove("total_cached_tokens")
        .filter(|value| value.as_u64().is_some());
    let total_thought = normalized
        .remove("total_thought_tokens")
        .filter(|value| value.as_u64().is_some());

    if !normalized.contains_key("input_tokens")
        && let Some(input_tokens) = total_input
    {
        normalized.insert("input_tokens".to_string(), input_tokens);
    }
    if !normalized.contains_key("output_tokens") {
        if let Some(output_tokens) = total_output {
            normalized.insert("output_tokens".to_string(), output_tokens);
        } else if normalized.contains_key("input_tokens") {
            normalized.insert("output_tokens".to_string(), json!(0));
        }
    }
    if let Some(cached_tokens) = total_cached {
        let mut details = normalized
            .remove("input_tokens_details")
            .and_then(|value| match value {
                Value::Object(map) => Some(map),
                _other => None,
            })
            .unwrap_or_default();
        details
            .entry("cached_tokens".to_string())
            .or_insert(cached_tokens);
        normalized.insert("input_tokens_details".to_string(), Value::Object(details));
    }
    if let Some(reasoning_tokens) = total_thought {
        let mut details = normalized
            .remove("output_tokens_details")
            .and_then(|value| match value {
                Value::Object(map) => Some(map),
                _other => None,
            })
            .unwrap_or_default();
        details
            .entry("reasoning_tokens".to_string())
            .or_insert(reasoning_tokens);
        normalized.insert("output_tokens_details".to_string(), Value::Object(details));
    }

    Value::Object(normalized)
}
