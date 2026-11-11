use super::*;

/// Cloudflare decision models: Clef on Workers AI and partner models such as
/// Jev behind the unified `ai/run` endpoint.
#[derive(Debug)]
pub(super) struct CloudflareDecision;

impl APIProtocol for CloudflareDecision {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        let request = context.resolved_provider_request_object();
        let mut input = Map::new();

        // `state` is required and may be null, so it is copied as given.
        input.insert(
            "state".to_string(),
            request.get("state").cloned().unwrap_or(Value::Null),
        );
        maybe_put_from(&mut input, &request, "questions");
        maybe_put_from(&mut input, &request, "images");

        // Workers AI models take the fields at the top level and name the model
        // by its short id; partner models take them inside `input`.
        Ok(match context.model.strip_prefix("@cf/") {
            Some(workers_model) => {
                let short_model = workers_model.rsplit('/').next().unwrap_or(workers_model);
                input.insert("model".to_string(), json!(short_model));
                input
            }
            None => {
                let mut body = Map::new();
                body.insert("model".to_string(), json!(context.model));
                body.insert("input".to_string(), Value::Object(input));
                body
            }
        })
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        let object = provider_object_body(status, body, "Cloudflare decision")?;
        let payload = cloudflare_result(object);

        normalize_decision_payload(context, status, payload, "Cloudflare decision")
    }
}

#[derive(Debug)]
pub(super) struct SystemOneDecision;

impl APIProtocol for SystemOneDecision {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        let mut body = context.resolved_provider_request_object();
        let state = body.remove("state").unwrap_or(Value::Null);
        let images = body.remove("images").unwrap_or(Value::Null);
        body.remove("stream");

        if images.is_null() {
            body.insert("state".to_string(), systemone_state(state)?);
            return Ok(body);
        }

        let images = images.as_array().ok_or_else(|| {
            StreamError::new(
                "invalid_decision_request",
                "api_resolver",
                "SystemOne decision images must be an array",
            )
        })?;
        let occupied = format!(
            "{}{}",
            sonic_rs::to_string(&body).unwrap_or_default(),
            sonic_rs::to_string(&state).unwrap_or_default()
        );
        let mut assets = Map::new();
        let mut references = Vec::with_capacity(images.len());

        for (index, image) in images.iter().enumerate() {
            let (format, data_base64) = systemone_image(image).ok_or_else(|| {
                StreamError::new(
                    "invalid_decision_request",
                    "api_resolver",
                    "SystemOne decision images must be PNG or JPEG base64 data URLs",
                )
            })?;
            let id = unused_asset_id(index + 1, &occupied);
            references.push(Value::String(id.clone()));
            assets.insert(
                id,
                json!({"type": "image", "format": format, "data_base64": data_base64}),
            );
        }

        body.insert(
            "state".to_string(),
            attach_systemone_references(systemone_state(state)?, references),
        );
        body.insert("assets".to_string(), Value::Object(assets));
        Ok(body)
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        let payload = provider_object_body(status, body, "SystemOne decision")?;
        normalize_decision_payload(context, status, payload, "SystemOne decision")
    }
}

fn normalize_decision_payload(
    context: &ResponseContext,
    status: u16,
    payload: Value,
    label: &str,
) -> Result<Value, StreamError> {
    match payload.get("answers") {
        Some(answers) if answers.is_object() => Ok(json!({
            "model": payload.get("model").and_then(Value::as_str).unwrap_or(&context.model),
            "answers": answers,
            "usage": payload
                .get("usage")
                .filter(|usage| usage.is_object())
                .cloned()
                .unwrap_or_else(|| json!({}))
        })),
        _answers => Err(invalid_upstream_body_error(
            status,
            payload,
            format!("{label} response did not contain answers"),
        )),
    }
}

fn systemone_state(state: Value) -> Result<Value, StreamError> {
    match state {
        Value::Object(_) | Value::Array(_) | Value::String(_) => Ok(state),
        Value::Null | Value::Bool(_) | Value::Number(_) => sonic_rs::to_string(&state)
            .map(Value::String)
            .map_err(|reason| {
                StreamError::new(
                    "request_encode_failed",
                    "api_resolver",
                    format!("SystemOne decision state could not be encoded as JSON: {reason}"),
                )
            }),
    }
}

fn systemone_image(image: &Value) -> Option<(&'static str, &str)> {
    let rest = image.as_str()?.strip_prefix("data:")?;
    let (media_type, data_base64) = rest.split_once(";base64,")?;
    let format = match media_type {
        "image/png" => "png",
        "image/jpeg" => "jpeg",
        _media_type => return None,
    };
    (!data_base64.is_empty()).then_some((format, data_base64))
}

fn unused_asset_id(index: usize, occupied: &str) -> String {
    let base = format!("ankole-image-{index}");
    if !occupied.contains(&base) {
        return base;
    }

    let mut suffix = 2;
    loop {
        let candidate = format!("{base}-{suffix}");
        if !occupied.contains(&candidate) {
            return candidate;
        }
        suffix += 1;
    }
}

fn attach_systemone_references(state: Value, references: Vec<Value>) -> Value {
    match state {
        Value::Object(mut object) => {
            let base = "__ankole_images";
            let mut key = base.to_string();
            let mut suffix = 2;
            while object.contains_key(&key) {
                key = format!("{base}-{suffix}");
                suffix += 1;
            }
            object.insert(key, Value::Array(references));
            Value::Object(object)
        }
        Value::Array(mut array) => {
            array.push(Value::Array(references));
            Value::Array(array)
        }
        state => json!([state, references]),
    }
}

const OPENAI_DECISION_MAX_JSON_BYTES: usize = 256 * 1024;
const OPENAI_DECISION_MAX_JSON_DEPTH: usize = 32;
const OPENAI_DECISION_MAX_JSON_VALUES: usize = 10_000;
const OPENAI_DECISION_MAX_INSTRUCTIONS_STRING_BYTES: usize = 1024 * 1024;

#[derive(Debug)]
pub(super) struct OpenAIDecision;

impl APIProtocol for OpenAIDecision {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        let request = context.resolved_provider_request_object();
        let state = request.get("state").cloned().unwrap_or(Value::Null);
        let images = request.get("images").cloned().unwrap_or(Value::Null);
        let questions = request.get("questions").cloned().unwrap_or(Value::Null);
        let mut body = request;
        body.remove("state");
        body.remove("images");
        body.remove("stream");
        body.insert("input".to_string(), openai_decision_input(state, images)?);
        body.insert(
            "questions".to_string(),
            openai_decision_questions(&questions)?,
        );
        Ok(body)
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        let payload = provider_object_body(status, body, "OpenAI decision")?;
        let answers = payload
            .get("answers")
            .and_then(Value::as_array)
            .ok_or_else(|| {
                invalid_upstream_body_error(
                    status,
                    payload.clone(),
                    "OpenAI decision response did not contain an answers array",
                )
            })?;
        let requested_questions = context.request.get("questions").and_then(Value::as_object);
        let mut normalized = Map::new();

        for answer in answers {
            if answer.get("type").and_then(Value::as_str) == Some("refusal") {
                let name = answer
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown");
                return Err(StreamError::new(
                    "upstream_decision_refusal",
                    "api_resolver",
                    format!("OpenAI decision model refused to answer question {name}"),
                )
                .provider_status(status)
                .provider_error_type("refusal")
                .provider_body_excerpt(sonic_rs::to_vec(&payload).unwrap_or_default()));
            }

            let name = answer.get("name").and_then(Value::as_str).ok_or_else(|| {
                invalid_upstream_body_error(
                    status,
                    payload.clone(),
                    "OpenAI decision answer did not contain a question name",
                )
            })?;
            if normalized.contains_key(name) {
                return Err(invalid_upstream_body_error(
                    status,
                    payload.clone(),
                    "OpenAI decision response contained a duplicate question name",
                ));
            }
            let requested_question = match requested_questions {
                Some(questions) => Some(questions.get(name).ok_or_else(|| {
                    invalid_upstream_body_error(
                        status,
                        payload.clone(),
                        format!("OpenAI decision response answered unknown question {name}"),
                    )
                })?),
                None => None,
            };
            let answer =
                normalize_openai_decision_answer(answer, requested_question).ok_or_else(|| {
                    invalid_upstream_body_error(
                        status,
                        payload.clone(),
                        format!("OpenAI decision answer for {name} had an invalid shape"),
                    )
                })?;
            normalized.insert(name.to_string(), answer);
        }

        if let Some(questions) = requested_questions
            && (normalized.len() != questions.len()
                || questions.keys().any(|name| !normalized.contains_key(name)))
        {
            return Err(invalid_upstream_body_error(
                status,
                payload.clone(),
                "OpenAI decision response did not answer every question",
            ));
        }

        Ok(json!({
            "model": payload.get("model").and_then(Value::as_str).unwrap_or(&context.model),
            "answers": normalized,
            "usage": payload
                .get("usage")
                .filter(|usage| usage.is_object())
                .cloned()
                .unwrap_or_else(|| json!({}))
        }))
    }
}

fn openai_decision_input(state: Value, images: Value) -> Result<Value, StreamError> {
    let images = match images {
        Value::Null => Vec::new(),
        Value::Array(images) => images,
        _images => {
            return Err(StreamError::new(
                "invalid_decision_request",
                "api_resolver",
                "OpenAI decision images must be an array",
            ));
        }
    };

    if images.is_empty()
        && let Value::String(text) = &state
    {
        return Ok(Value::String(text.clone()));
    }

    let mut content = Vec::new();
    if openai_decision_structured_input(&state) {
        content.push(json!({"type": "input_json", "data": state}));
    } else {
        content.push(json!({
            "type": "input_text",
            "text": openai_decision_text(&state)?
        }));
    }

    for image in images {
        let image_url = image.as_str().ok_or_else(|| {
            StreamError::new(
                "invalid_decision_request",
                "api_resolver",
                "OpenAI decision images must be base64 data URLs",
            )
        })?;
        content.push(json!({"type": "input_image", "image_url": image_url}));
    }

    Ok(json!([{"type": "message", "role": "user", "content": content}]))
}

fn openai_decision_structured_input(state: &Value) -> bool {
    let shape_matches = match state {
        Value::Object(_) => true,
        Value::Array(items) => items.iter().all(Value::is_object),
        _state => false,
    };
    if !shape_matches
        || sonic_rs::to_vec(state)
            .map(|encoded| encoded.len() > OPENAI_DECISION_MAX_JSON_BYTES)
            .unwrap_or(true)
    {
        return false;
    }

    let mut values = 0;
    openai_decision_json_within_limits(state, 1, &mut values)
}

fn openai_decision_json_within_limits(value: &Value, depth: usize, values: &mut usize) -> bool {
    if depth > OPENAI_DECISION_MAX_JSON_DEPTH {
        return false;
    }
    *values += 1;
    if *values > OPENAI_DECISION_MAX_JSON_VALUES {
        return false;
    }

    match value {
        Value::Object(object) => object
            .values()
            .all(|value| openai_decision_json_within_limits(value, depth + 1, values)),
        Value::Array(array) => array
            .iter()
            .all(|value| openai_decision_json_within_limits(value, depth + 1, values)),
        _scalar => true,
    }
}

fn openai_decision_questions(questions: &Value) -> Result<Value, StreamError> {
    let questions = questions.as_object().ok_or_else(|| {
        StreamError::new(
            "invalid_decision_request",
            "api_resolver",
            "OpenAI decision questions must be an object",
        )
    })?;
    let mut questions = questions.iter().collect::<Vec<_>>();
    questions.sort_by_key(|(left, _)| *left);
    let mut converted = Vec::with_capacity(questions.len());

    for (name, question) in questions {
        let mut result = Map::new();
        result.insert("name".to_string(), json!(name));
        let question_type = question
            .get("type")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                StreamError::new(
                    "invalid_decision_request",
                    "api_resolver",
                    format!("OpenAI decision question {name} did not contain a type"),
                )
            })?;
        result.insert("type".to_string(), json!(question_type));

        match question_type {
            "noul" => {
                result["type"] = json!("predicate");
                let instructions = question.get("instructions").cloned().unwrap_or(Value::Null);
                result.insert(
                    "instructions".to_string(),
                    match question.get("criteria") {
                        Some(criteria) if !criteria.is_null() => {
                            openai_decision_instructions(&json!({
                                "instructions": instructions,
                                "criteria": criteria
                            }))?
                        }
                        _criteria => openai_decision_instructions(&instructions)?,
                    },
                );
            }
            "choice" => {
                let criteria = question
                    .get("criteria")
                    .and_then(Value::as_object)
                    .ok_or_else(|| {
                        invalid_openai_question(name, "choice criteria must be an object")
                    })?;
                let mut choices = criteria.iter().collect::<Vec<_>>();
                choices.sort_by_key(|(left, _)| *left);
                let choices = choices
                    .into_iter()
                    .map(|(value, description)| {
                        let mut choice = json!({"value": value});
                        if !description.is_null() {
                            choice["description"] = openai_decision_text_value(description)?;
                        }
                        Ok(choice)
                    })
                    .collect::<Result<Vec<_>, StreamError>>()?;
                result.insert("choices".to_string(), Value::Array(choices));
                result.insert(
                    "instructions".to_string(),
                    openai_decision_instructions(
                        question.get("instructions").unwrap_or(&Value::Null),
                    )?,
                );
            }
            "score" => {
                let criteria = question
                    .get("criteria")
                    .and_then(Value::as_array)
                    .ok_or_else(|| {
                        invalid_openai_question(name, "score criteria must be an array")
                    })?;
                let mut levels = Vec::with_capacity(criteria.len());
                for criterion in criteria {
                    levels.push(json!({"label": openai_decision_text(criterion)?}));
                }
                result.insert("levels".to_string(), Value::Array(levels));
                result.insert(
                    "instructions".to_string(),
                    openai_decision_instructions(
                        question.get("instructions").unwrap_or(&Value::Null),
                    )?,
                );
            }
            _question_type => {
                return Err(invalid_openai_question(name, "unsupported question type"));
            }
        }

        converted.push(Value::Object(result));
    }

    Ok(Value::Array(converted))
}

fn invalid_openai_question(name: &str, message: &str) -> StreamError {
    StreamError::new(
        "invalid_decision_request",
        "api_resolver",
        format!("OpenAI decision question {name}: {message}"),
    )
}

fn openai_decision_instructions(value: &Value) -> Result<Value, StreamError> {
    let text = openai_decision_text(value)?;
    if text.len() <= OPENAI_DECISION_MAX_INSTRUCTIONS_STRING_BYTES {
        Ok(Value::String(text))
    } else {
        Ok(json!([{"type": "input_text", "text": text}]))
    }
}

fn openai_decision_text_value(value: &Value) -> Result<Value, StreamError> {
    match value {
        Value::String(_) => Ok(value.clone()),
        _value => Ok(Value::String(openai_decision_text(value)?)),
    }
}

fn openai_decision_text(value: &Value) -> Result<String, StreamError> {
    match value {
        Value::String(text) => Ok(text.clone()),
        _value => sonic_rs::to_string(value).map_err(|reason| {
            StreamError::new(
                "request_encode_failed",
                "api_resolver",
                format!("OpenAI decision text could not be encoded as JSON: {reason}"),
            )
        }),
    }
}

fn normalize_openai_decision_answer(
    answer: &Value,
    requested_question: Option<&Value>,
) -> Option<Value> {
    let requested_type = requested_question
        .and_then(|question| question.get("type"))
        .and_then(Value::as_str);

    match answer.get("type").and_then(Value::as_str)? {
        "predicate" => {
            if requested_type.is_some_and(|kind| kind != "noul") {
                return None;
            }
            Some(json!({
                "type": "noul",
                "noul": answer.get("probability").filter(|value| value.is_number())?
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
            for entry in answer.get("probabilities")?.as_array()? {
                let value = entry.get("value")?.as_str().filter(|s| !s.is_empty())?;
                if let Some(criteria) = criteria
                    && !criteria.contains_key(value)
                {
                    return None;
                }
                let probability = entry.get("probability").filter(|value| value.is_number())?;
                probabilities.insert(value.to_string(), probability.clone());
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
            let mut legend = Map::new();
            let mut probabilities = Map::new();
            for entry in answer.get("probabilities")?.as_array()? {
                let index = usize::try_from(entry.get("value")?.as_u64()?).ok()?;
                let label = entry.get("label")?.as_str()?;
                let probability = entry.get("probability").filter(|value| value.is_number())?;
                let legend_value = match criteria {
                    Some(items) => items.get(index)?.clone(),
                    None => json!(label),
                };
                let key = index.to_string();
                legend.insert(key.clone(), legend_value);
                probabilities.insert(key, probability.clone());
            }
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
