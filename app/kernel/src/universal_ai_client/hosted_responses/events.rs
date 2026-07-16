use serde_json::{Value, json};

pub(super) fn terminal_stream_events(sequence: &mut u64, response: &Value) -> Vec<Value> {
    let response = strip_internal_output_fields(response.clone());
    let terminal_event = match response.get("status").and_then(Value::as_str) {
        Some("incomplete") => "response.incomplete",
        Some("failed") => "response.failed",
        _status => "response.completed",
    };
    vec![stream_event(
        sequence,
        terminal_event,
        json!({"response": response}),
    )]
}

pub(super) fn output_item_events(
    sequence: &mut u64,
    output_index: usize,
    item: &Value,
) -> Vec<Value> {
    match item.get("type").and_then(Value::as_str) {
        Some("image_generation_call") => image_item_events(sequence, output_index, item),
        Some("message") => message_item_events(sequence, output_index, item),
        Some("function_call") => function_item_events(sequence, output_index, item),
        _type => generic_item_events(sequence, output_index, item),
    }
}

pub(super) fn image_item_events(
    sequence: &mut u64,
    output_index: usize,
    item: &Value,
) -> Vec<Value> {
    let item_id = item.get("id").and_then(Value::as_str).unwrap_or_default();
    let partial_images = item
        .get("partial_images")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut events = image_started_events(sequence, output_index, item_id);

    for (partial_image_index, partial_image) in partial_images.into_iter().enumerate() {
        events.push(stream_event(
            sequence,
            "response.image_generation_call.partial_image",
            json!({
                "item_id": item_id,
                "output_index": output_index,
                "partial_image_index": partial_image_index,
                "partial_image_b64": partial_image
            }),
        ));
    }

    events.extend(image_completed_events(sequence, output_index, item));
    events
}

pub(super) fn image_started_events(
    sequence: &mut u64,
    output_index: usize,
    item_id: &str,
) -> Vec<Value> {
    let in_progress = json!({
        "id": item_id,
        "type": "image_generation_call",
        "status": "in_progress",
        "result": null
    });

    vec![
        stream_event(
            sequence,
            "response.output_item.added",
            json!({"output_index": output_index, "item": in_progress}),
        ),
        stream_event(
            sequence,
            "response.image_generation_call.in_progress",
            json!({"item_id": item_id, "output_index": output_index}),
        ),
        stream_event(
            sequence,
            "response.image_generation_call.generating",
            json!({"item_id": item_id, "output_index": output_index}),
        ),
    ]
}

pub(super) fn image_completed_events(
    sequence: &mut u64,
    output_index: usize,
    item: &Value,
) -> Vec<Value> {
    let item_id = item.get("id").cloned().unwrap_or(Value::Null);
    let public_item = strip_internal_image_fields(item.clone());

    vec![
        stream_event(
            sequence,
            "response.image_generation_call.completed",
            json!({"item_id": item_id, "output_index": output_index}),
        ),
        stream_event(
            sequence,
            "response.output_item.done",
            json!({"output_index": output_index, "item": public_item}),
        ),
    ]
}

fn message_item_events(sequence: &mut u64, output_index: usize, item: &Value) -> Vec<Value> {
    let item_id = item.get("id").cloned().unwrap_or(Value::Null);
    let mut added = item.clone();
    added["status"] = json!("in_progress");
    added["content"] = json!([]);
    let mut events = vec![stream_event(
        sequence,
        "response.output_item.added",
        json!({"output_index": output_index, "item": added}),
    )];

    for (content_index, part) in item
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .enumerate()
    {
        let text = part.get("text").and_then(Value::as_str).unwrap_or("");
        let mut empty_part = part.clone();
        empty_part["text"] = json!("");
        events.push(stream_event(
            sequence,
            "response.content_part.added",
            json!({
                "item_id": item_id,
                "output_index": output_index,
                "content_index": content_index,
                "part": empty_part
            }),
        ));
        if part.get("type").and_then(Value::as_str) == Some("output_text") && !text.is_empty() {
            events.push(stream_event(
                sequence,
                "response.output_text.delta",
                json!({
                    "item_id": item_id,
                    "output_index": output_index,
                    "content_index": content_index,
                    "delta": text
                }),
            ));
            events.push(stream_event(
                sequence,
                "response.output_text.done",
                json!({
                    "item_id": item_id,
                    "output_index": output_index,
                    "content_index": content_index,
                    "text": text
                }),
            ));
        }
        events.push(stream_event(
            sequence,
            "response.content_part.done",
            json!({
                "item_id": item_id,
                "output_index": output_index,
                "content_index": content_index,
                "part": part
            }),
        ));
    }
    events.push(stream_event(
        sequence,
        "response.output_item.done",
        json!({"output_index": output_index, "item": item}),
    ));
    events
}

fn function_item_events(sequence: &mut u64, output_index: usize, item: &Value) -> Vec<Value> {
    let item_id = item.get("id").cloned().unwrap_or(Value::Null);
    let arguments = item.get("arguments").and_then(Value::as_str).unwrap_or("");
    let mut added = item.clone();
    added["status"] = json!("in_progress");
    added["arguments"] = json!("");
    let mut events = vec![stream_event(
        sequence,
        "response.output_item.added",
        json!({"output_index": output_index, "item": added}),
    )];
    if !arguments.is_empty() {
        events.push(stream_event(
            sequence,
            "response.function_call_arguments.delta",
            json!({
                "item_id": item_id,
                "output_index": output_index,
                "delta": arguments
            }),
        ));
    }
    events.push(stream_event(
        sequence,
        "response.function_call_arguments.done",
        json!({
            "item_id": item_id,
            "output_index": output_index,
            "arguments": arguments
        }),
    ));
    events.push(stream_event(
        sequence,
        "response.output_item.done",
        json!({"output_index": output_index, "item": item}),
    ));
    events
}

fn generic_item_events(sequence: &mut u64, output_index: usize, item: &Value) -> Vec<Value> {
    vec![
        stream_event(
            sequence,
            "response.output_item.added",
            json!({"output_index": output_index, "item": item}),
        ),
        stream_event(
            sequence,
            "response.output_item.done",
            json!({"output_index": output_index, "item": item}),
        ),
    ]
}

pub(super) fn stream_event(sequence: &mut u64, event_type: &str, fields: Value) -> Value {
    let current = *sequence;
    *sequence = sequence.saturating_add(1);
    let mut event = json!({"type": event_type, "sequence_number": current});
    if let Some(fields) = fields.as_object() {
        for (key, value) in fields {
            event[key] = value.clone();
        }
    }
    event
}

pub(super) fn strip_internal_output_fields(mut response: Value) -> Value {
    if let Some(output) = response.get_mut("output").and_then(Value::as_array_mut) {
        for item in output {
            if item.get("type").and_then(Value::as_str) == Some("image_generation_call")
                && let Some(object) = item.as_object_mut()
            {
                object.remove("mime_type");
                object.remove("partial_images");
            }
        }
    }
    response
}

pub(super) fn strip_internal_image_fields(mut item: Value) -> Value {
    if let Some(object) = item.as_object_mut() {
        object.remove("mime_type");
        object.remove("partial_images");
    }
    item
}
