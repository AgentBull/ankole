use super::*;
use crate::common::{base64_url_safe_decode, base64_url_safe_encode};

const OPAQUE_CONTENT_PREFIX: &str = "ankole-aigateway-opaque-v1:";
const LEGACY_CHAT_CONTENT_PREFIX: &str = "ankole-chat-encoded-v1:";
const NATIVE_ENCRYPTED_TOOL_FIELDS: &str = "__ankole_native_encrypted_tool_fields";

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct ToolIdentity {
    namespace: Option<String>,
    name: String,
}

#[derive(Debug, Default)]
struct ToolFieldPlan {
    by_identity: BTreeMap<ToolIdentity, BTreeSet<String>>,
    by_provider_name: BTreeMap<String, BTreeSet<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum StreamCallMode {
    Unknown,
    Plain,
    Opaque(BTreeSet<String>),
}

#[derive(Debug, Clone)]
struct StreamCall {
    mode: StreamCallMode,
    arguments: String,
    item_id: Option<String>,
    output_index: Option<u64>,
    pending_done: Option<Value>,
    encoded_arguments: Option<String>,
    plain_delta_emitted: bool,
    encoded_delta_emitted: bool,
    arguments_done_emitted: bool,
    item: Option<Value>,
}

impl StreamCall {
    fn new(mode: StreamCallMode, event: &Value) -> Self {
        Self {
            mode,
            arguments: String::new(),
            item_id: event
                .get("item_id")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            output_index: event.get("output_index").and_then(Value::as_u64),
            pending_done: None,
            encoded_arguments: None,
            plain_delta_emitted: false,
            encoded_delta_emitted: false,
            arguments_done_emitted: false,
            item: None,
        }
    }

    fn update_event_identity(&mut self, event: &Value) {
        if self.item_id.is_none() {
            self.item_id = event
                .get("item_id")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned);
        }
        if self.output_index.is_none() {
            self.output_index = event.get("output_index").and_then(Value::as_u64);
        }
    }
}

#[derive(Debug, Default)]
pub(super) struct OpaqueToolFields {
    plan: ToolFieldPlan,
    stream_calls: BTreeMap<String, StreamCall>,
    next_sequence: u64,
    terminal: bool,
    last_response: Option<Value>,
}

impl OpaqueToolFields {
    pub(super) fn prepare(
        kind: APIResolverKind,
        context: &ResponseContext,
    ) -> Result<(Self, ResponseContext), StreamError> {
        let mut provider_context = context.clone();

        let native_encrypted_tool_fields = context
            .request
            .get(NATIVE_ENCRYPTED_TOOL_FIELDS)
            .and_then(Value::as_bool)
            .unwrap_or(false);

        if native_encrypted_tool_fields {
            if !openai_responses_wire(kind) {
                return Err(invalid_tool_schema_error(
                    "native encrypted tool fields require the OpenAI Responses wire protocol",
                ));
            }
            normalize_context_tool_markers(&mut provider_context, false)?;
            lower_context(&mut provider_context, true)?;
            return Ok((Self::inactive(), provider_context));
        }

        let plan = ToolFieldPlan::from_context(context)?;
        normalize_context_tool_markers(&mut provider_context, true)?;
        lower_context(&mut provider_context, openai_responses_wire(kind))?;

        Ok((
            Self {
                plan,
                ..Self::default()
            },
            provider_context,
        ))
    }

    pub(super) fn inactive() -> Self {
        Self::default()
    }

    pub(super) fn lift_events(&mut self, events: Vec<Value>) -> Result<Vec<Value>, StreamError> {
        if !self.active() {
            return Ok(events);
        }

        let mut lifted = Vec::new();
        for event in events {
            self.lift_event(event, &mut lifted)?;
        }
        self.resequence(&mut lifted);
        Ok(lifted)
    }

    pub(super) fn lift_response(&self, mut response: Value) -> Result<Value, StreamError> {
        if !self.active() {
            return Ok(response);
        }

        let completed = response.get("status").and_then(Value::as_str) == Some("completed");
        if completed {
            self.encode_response_output(&mut response)?;
        } else {
            redact_function_call_arguments(&mut response);
        }
        Ok(response)
    }

    pub(super) fn fail_events(
        &mut self,
        context: &ResponseContext,
        error: &StreamError,
        events: Vec<Value>,
    ) -> Vec<Value> {
        if !self.active() {
            return events;
        }
        if self.terminal {
            return Vec::new();
        }

        let mut failed = Vec::new();
        let mut has_error = false;
        let mut has_terminal = false;
        for mut event in events {
            match event.get("type").and_then(Value::as_str) {
                Some("error") => has_error = true,
                Some("response.failed") => {
                    has_terminal = true;
                    if let Some(response) = event.get_mut("response") {
                        redact_function_call_arguments(response);
                        response["status"] = json!("failed");
                        response["completed_at"] = Value::Null;
                        response["error"] = openresponses_error(error);
                        self.last_response = Some(response.clone());
                    }
                }
                _event => {}
            }
            failed.push(event);
        }

        if !has_error {
            failed.push(build_event(
                0,
                "error",
                json!({"error": openresponses_error(error)}),
            ));
        }
        if !has_terminal {
            let mut response = self.last_response.clone().unwrap_or_else(|| {
                complete_response_resource(
                    context,
                    json!({
                        "status": "failed",
                        "output": [],
                        "error": openresponses_error(error)
                    }),
                )
            });
            if response
                .get("output")
                .and_then(Value::as_array)
                .is_none_or(Vec::is_empty)
            {
                response["output"] = Value::Array(self.partial_stream_output());
            }
            redact_function_call_arguments(&mut response);
            response["status"] = json!("failed");
            response["completed_at"] = Value::Null;
            response["error"] = openresponses_error(error);
            failed.push(build_event(
                0,
                "response.failed",
                json!({"response": response}),
            ));
        }

        self.stream_calls.clear();
        self.terminal = true;
        self.resequence(&mut failed);
        failed
    }

    pub(super) fn is_terminal(&self) -> bool {
        self.terminal
    }

    fn active(&self) -> bool {
        !self.plan.by_identity.is_empty()
    }

    fn lift_event(&mut self, event: Value, lifted: &mut Vec<Value>) -> Result<(), StreamError> {
        match event.get("type").and_then(Value::as_str) {
            Some("response.output_item.added") => self.lift_output_item_added(event, lifted),
            Some("response.function_call_arguments.delta") => {
                self.lift_arguments_delta(event, lifted)
            }
            Some("response.function_call_arguments.done") => {
                self.lift_arguments_done(event, lifted)
            }
            Some("response.output_item.done") => self.lift_output_item_done(event, lifted),
            Some("response.completed" | "response.failed" | "response.incomplete") => {
                self.lift_terminal_event(event, lifted)
            }
            _event => {
                if let Some(response) = event.get("response").filter(|value| value.is_object()) {
                    let mut response = response.clone();
                    redact_in_progress_opaque_calls(&self.plan, &mut response);
                    self.last_response = Some(response);
                }
                lifted.push(event);
                Ok(())
            }
        }
    }

    fn lift_output_item_added(
        &mut self,
        mut event: Value,
        lifted: &mut Vec<Value>,
    ) -> Result<(), StreamError> {
        let Some(mut item) = event.get("item").cloned() else {
            lifted.push(event);
            return Ok(());
        };
        if item.get("type").and_then(Value::as_str) != Some("function_call") {
            lifted.push(event);
            return Ok(());
        }

        let locator = call_locator(&event, Some(&item)).ok_or_else(missing_call_identity_error)?;
        let mode = self.plan.stream_mode(&item);
        let raw_arguments = item_arguments(&item);
        let mut pending_plain_delta = None;
        {
            let state = self
                .stream_calls
                .entry(locator)
                .or_insert_with(|| StreamCall::new(mode.clone(), &event));
            state.update_event_identity(&event);
            if !raw_arguments.is_empty() {
                state.arguments.push_str(&raw_arguments);
            }
            if state.mode == StreamCallMode::Unknown {
                state.mode = mode.clone();
            }
            state.item = Some(item.clone());

            match mode {
                StreamCallMode::Plain => {
                    if !state.arguments.is_empty() && !state.plain_delta_emitted {
                        pending_plain_delta = Some(stream_delta_event(state, &state.arguments));
                        state.plain_delta_emitted = true;
                    }
                }
                StreamCallMode::Unknown | StreamCallMode::Opaque(_) => {
                    item["arguments"] = json!("");
                }
            }
        }

        event["item"] = item;
        lifted.push(event);
        if let Some(delta) = pending_plain_delta {
            lifted.push(delta);
        }
        Ok(())
    }

    fn lift_arguments_delta(
        &mut self,
        event: Value,
        lifted: &mut Vec<Value>,
    ) -> Result<(), StreamError> {
        let locator = call_locator(&event, None).ok_or_else(missing_call_identity_error)?;
        let delta = event
            .get("delta")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let state = self
            .stream_calls
            .entry(locator)
            .or_insert_with(|| StreamCall::new(StreamCallMode::Unknown, &event));
        state.update_event_identity(&event);
        state.arguments.push_str(delta);

        if state.mode == StreamCallMode::Plain {
            state.plain_delta_emitted = true;
            lifted.push(event);
        }
        Ok(())
    }

    fn lift_arguments_done(
        &mut self,
        mut event: Value,
        lifted: &mut Vec<Value>,
    ) -> Result<(), StreamError> {
        let locator = call_locator(&event, None).ok_or_else(missing_call_identity_error)?;
        let raw_arguments = event
            .get("arguments")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let state = self
            .stream_calls
            .entry(locator)
            .or_insert_with(|| StreamCall::new(StreamCallMode::Unknown, &event));
        state.update_event_identity(&event);
        if !raw_arguments.is_empty() {
            state.arguments = raw_arguments;
        }

        match &state.mode {
            StreamCallMode::Plain => {
                state.arguments_done_emitted = true;
                lifted.push(event);
            }
            StreamCallMode::Unknown => {
                state.pending_done = Some(event);
            }
            StreamCallMode::Opaque(fields) => {
                let encoded = encode_tool_arguments(fields, &state.arguments)?;
                if !state.encoded_delta_emitted {
                    lifted.push(stream_delta_event(state, &encoded));
                    state.encoded_delta_emitted = true;
                }
                event["arguments"] = json!(encoded.clone());
                state.encoded_arguments = Some(encoded);
                state.arguments_done_emitted = true;
                lifted.push(event);
            }
        }
        Ok(())
    }

    fn lift_output_item_done(
        &mut self,
        mut event: Value,
        lifted: &mut Vec<Value>,
    ) -> Result<(), StreamError> {
        let Some(mut item) = event.get("item").cloned() else {
            lifted.push(event);
            return Ok(());
        };
        if item.get("type").and_then(Value::as_str) != Some("function_call") {
            lifted.push(event);
            return Ok(());
        }

        let locator = call_locator(&event, Some(&item)).ok_or_else(missing_call_identity_error)?;
        let final_mode = self.plan.stream_mode(&item);
        let mut state = self
            .stream_calls
            .remove(&locator)
            .unwrap_or_else(|| StreamCall::new(final_mode.clone(), &event));
        state.update_event_identity(&event);
        let item_raw_arguments = item_arguments(&item);
        if !item_raw_arguments.is_empty() {
            state.arguments = item_raw_arguments;
        }
        state.item = Some(item.clone());
        self.stream_calls.insert(locator.clone(), state.clone());

        match final_mode.clone() {
            StreamCallMode::Unknown => {
                return Err(StreamError::new(
                    "invalid_encrypted_tool_arguments",
                    "api_resolver",
                    "AIGateway cannot classify a completed function call without a stable tool name",
                ));
            }
            StreamCallMode::Plain => {
                if matches!(state.mode, StreamCallMode::Opaque(_)) && state.encoded_delta_emitted {
                    return Err(unstable_call_name_error());
                }
                if !state.arguments.is_empty() && !state.plain_delta_emitted {
                    lifted.push(stream_delta_event(&state, &state.arguments));
                    state.plain_delta_emitted = true;
                }
                if let Some(mut done) = state.pending_done.take() {
                    done["arguments"] = json!(state.arguments.clone());
                    lifted.push(done);
                    state.arguments_done_emitted = true;
                } else if !state.arguments_done_emitted {
                    lifted.push(stream_done_event(&state, &state.arguments));
                    state.arguments_done_emitted = true;
                }
            }
            StreamCallMode::Opaque(fields) => {
                if state.mode == StreamCallMode::Plain && state.plain_delta_emitted {
                    return Err(unstable_call_name_error());
                }
                let encoded = match state.encoded_arguments.clone() {
                    Some(encoded) => encoded,
                    None => encode_tool_arguments(&fields, &state.arguments)?,
                };
                if !state.encoded_delta_emitted {
                    lifted.push(stream_delta_event(&state, &encoded));
                    state.encoded_delta_emitted = true;
                }
                if let Some(mut done) = state.pending_done.take() {
                    done["arguments"] = json!(encoded.clone());
                    lifted.push(done);
                    state.arguments_done_emitted = true;
                } else if !state.arguments_done_emitted {
                    lifted.push(stream_done_event(&state, &encoded));
                    state.arguments_done_emitted = true;
                }
                state.encoded_arguments = Some(encoded.clone());
                item["arguments"] = json!(encoded);
            }
        }

        state.mode = final_mode;
        state.item = Some(item.clone());
        event["item"] = item;
        lifted.push(event);
        self.stream_calls.insert(locator, state);
        Ok(())
    }

    fn lift_terminal_event(
        &mut self,
        mut event: Value,
        lifted: &mut Vec<Value>,
    ) -> Result<(), StreamError> {
        let completed = event.get("type").and_then(Value::as_str) == Some("response.completed");
        if let Some(response) = event.get_mut("response") {
            if completed {
                self.encode_response_output(response)?;
            } else {
                redact_function_call_arguments(response);
            }
            self.last_response = Some(response.clone());
        }
        self.stream_calls.clear();
        self.terminal = true;
        lifted.push(event);
        Ok(())
    }

    fn encode_response_output(&self, response: &mut Value) -> Result<(), StreamError> {
        let Some(items) = response.get_mut("output").and_then(Value::as_array_mut) else {
            return Ok(());
        };
        for item in items {
            self.plan.encode_output_item(item)?;
        }
        Ok(())
    }

    fn resequence(&mut self, events: &mut [Value]) {
        for event in events {
            event["sequence_number"] = json!(self.next_sequence);
            self.next_sequence = self.next_sequence.saturating_add(1);
        }
    }

    fn partial_stream_output(&self) -> Vec<Value> {
        self.stream_calls
            .values()
            .filter_map(|call| call.item.clone())
            .map(|mut item| {
                item["arguments"] = json!("");
                item["status"] = json!("incomplete");
                item
            })
            .collect()
    }
}

fn openai_responses_wire(kind: APIResolverKind) -> bool {
    matches!(
        kind,
        APIResolverKind::OpenAIResponses | APIResolverKind::OpenAIResponsesCompact
    )
}

impl ToolFieldPlan {
    fn from_context(context: &ResponseContext) -> Result<Self, StreamError> {
        let mut plan = Self::default();
        if let Some(tools) = context
            .request
            .get("tools")
            .or_else(|| context.provider_options.get("tools"))
        {
            plan.collect_tools(tools)?;
        }
        Ok(plan)
    }

    fn collect_tools(&mut self, tools: &Value) -> Result<(), StreamError> {
        let Some(tools) = tools.as_array() else {
            return Ok(());
        };
        for tool in tools {
            let Some(tool) = tool.as_object() else {
                continue;
            };
            match tool.get("type").and_then(Value::as_str) {
                Some("namespace") => {
                    let namespace = tool.get("name").and_then(Value::as_str).unwrap_or_default();
                    if let Some(children) = tool.get("tools").and_then(Value::as_array) {
                        for child in children {
                            if let Some(child) = child.as_object() {
                                self.collect_function(child, Some(namespace))?;
                            }
                        }
                    }
                }
                Some("function") => self.collect_function(tool, None)?,
                _tool => {}
            }
        }
        Ok(())
    }

    fn collect_function(
        &mut self,
        tool: &Map<String, Value>,
        namespace: Option<&str>,
    ) -> Result<(), StreamError> {
        let function = function_map(tool);
        let Some(name) = function.get("name").and_then(Value::as_str) else {
            return Ok(());
        };
        let Some(schema) = function
            .get("parameters")
            .or_else(|| function.get("input_schema"))
        else {
            return Ok(());
        };
        let fields = encrypted_schema_fields(schema)?;
        if fields.is_empty() {
            return Ok(());
        }

        let identity = ToolIdentity {
            namespace: namespace
                .filter(|namespace| !namespace.is_empty())
                .map(ToOwned::to_owned),
            name: name.to_string(),
        };
        if let Some(existing) = self.by_identity.get(&identity)
            && existing != &fields
        {
            return Err(ambiguous_tool_schema_error(name));
        }
        self.by_identity.insert(identity.clone(), fields.clone());

        let provider_name = identity
            .namespace
            .as_deref()
            .map(|namespace| flattened_namespace_tool_name(namespace, name))
            .unwrap_or_else(|| flattened_namespace_tool_name("", name));
        if let Some(existing) = self.by_provider_name.get(&provider_name)
            && existing != &fields
        {
            return Err(ambiguous_tool_schema_error(&provider_name));
        }
        self.by_provider_name.insert(provider_name, fields);
        Ok(())
    }

    fn fields_for_item(&self, item: &Value) -> Option<&BTreeSet<String>> {
        let name = item.get("name").and_then(Value::as_str)?;
        let namespace = item
            .get("namespace")
            .and_then(Value::as_str)
            .filter(|namespace| !namespace.is_empty());
        if let Some(namespace) = namespace {
            let identity = ToolIdentity {
                namespace: Some(namespace.to_string()),
                name: name.to_string(),
            };
            if let Some(fields) = self.by_identity.get(&identity) {
                return Some(fields);
            }
        }
        self.by_provider_name.get(name).or_else(|| {
            let identity = ToolIdentity {
                namespace: None,
                name: name.to_string(),
            };
            self.by_identity.get(&identity)
        })
    }

    fn stream_mode(&self, item: &Value) -> StreamCallMode {
        match item.get("name").and_then(Value::as_str) {
            None | Some("" | "unknown") => StreamCallMode::Unknown,
            Some(_name) => self
                .fields_for_item(item)
                .cloned()
                .map(StreamCallMode::Opaque)
                .unwrap_or(StreamCallMode::Plain),
        }
    }

    fn encode_output_item(&self, item: &mut Value) -> Result<(), StreamError> {
        if item.get("type").and_then(Value::as_str) != Some("function_call") {
            return Ok(());
        }
        let Some(fields) = self.fields_for_item(item) else {
            return Ok(());
        };
        let arguments = item_arguments(item);
        item["arguments"] = json!(encode_tool_arguments(fields, &arguments)?);
        Ok(())
    }
}

// Marker validation and marker removal are separate decisions. A Responses
// route whose provider owns the declared marker keeps it, but every route still
// has to reject a marker the Worker-facing contract does not allow, so
// validation runs even when removal does not.
fn normalize_context_tool_markers(
    context: &mut ResponseContext,
    remove_markers: bool,
) -> Result<(), StreamError> {
    for request in [&mut context.provider_options, &mut context.request] {
        for_each_tool_schema(request, &mut |schema| {
            encrypted_schema_fields(schema)?;
            if remove_markers {
                strip_direct_encrypted_markers(schema);
            }
            Ok(())
        })?;
    }
    Ok(())
}

fn for_each_tool_schema(
    request: &mut Value,
    apply: &mut impl FnMut(&mut Value) -> Result<(), StreamError>,
) -> Result<(), StreamError> {
    let Some(tools) = request.get_mut("tools").and_then(Value::as_array_mut) else {
        return Ok(());
    };
    for tool in tools {
        let Some(tool) = tool.as_object_mut() else {
            continue;
        };
        match tool.get("type").and_then(Value::as_str) {
            Some("namespace") => {
                if let Some(children) = tool.get_mut("tools").and_then(Value::as_array_mut) {
                    for child in children {
                        if let Some(child) = child.as_object_mut() {
                            for_each_function_schema(child, apply)?;
                        }
                    }
                }
            }
            Some("function") => for_each_function_schema(tool, apply)?,
            _tool => {}
        }
    }
    Ok(())
}

fn for_each_function_schema(
    tool: &mut Map<String, Value>,
    apply: &mut impl FnMut(&mut Value) -> Result<(), StreamError>,
) -> Result<(), StreamError> {
    let function = function_map_mut(tool);
    for key in ["parameters", "input_schema"] {
        if let Some(schema) = function.get_mut(key) {
            apply(schema)?;
        }
    }
    Ok(())
}

fn function_map(tool: &Map<String, Value>) -> &Map<String, Value> {
    tool.get("function")
        .and_then(Value::as_object)
        .unwrap_or(tool)
}

fn function_map_mut(tool: &mut Map<String, Value>) -> &mut Map<String, Value> {
    if tool.get("function").is_some_and(Value::is_object) {
        return tool
            .get_mut("function")
            .and_then(Value::as_object_mut)
            .expect("function object was checked");
    }
    tool
}

fn encrypted_schema_fields(schema: &Value) -> Result<BTreeSet<String>, StreamError> {
    let mut stripped = schema.clone();
    let mut fields = BTreeSet::new();
    if let Some(properties) = stripped
        .get_mut("properties")
        .and_then(Value::as_object_mut)
    {
        for (name, property) in properties {
            let Some(property) = property.as_object_mut() else {
                continue;
            };
            let Some(marker) = property.remove("encrypted") else {
                continue;
            };
            let Some(encrypted) = marker.as_bool() else {
                return Err(invalid_tool_schema_error(
                    "encrypted tool parameter markers must be booleans",
                ));
            };
            if !encrypted {
                continue;
            }
            if property.get("type").and_then(Value::as_str) != Some("string") {
                return Err(invalid_tool_schema_error(
                    "encrypted tool parameters must be direct string properties",
                ));
            }
            fields.insert(name.clone());
        }
    }

    if contains_encrypted_annotation(&stripped) {
        return Err(invalid_tool_schema_error(
            "encrypted tool parameters support only direct object properties",
        ));
    }
    if !fields.is_empty() && schema.get("type").and_then(Value::as_str) != Some("object") {
        return Err(invalid_tool_schema_error(
            "encrypted tool parameters require an object schema",
        ));
    }
    Ok(fields)
}

fn strip_direct_encrypted_markers(schema: &mut Value) {
    if let Some(properties) = schema.get_mut("properties").and_then(Value::as_object_mut) {
        for property in properties.values_mut() {
            if let Some(property) = property.as_object_mut() {
                property.remove("encrypted");
            }
        }
    }
}

fn contains_encrypted_annotation(value: &Value) -> bool {
    match value {
        Value::Object(map) => {
            if map.contains_key("encrypted") {
                return true;
            }
            map.iter().any(|(key, child)| {
                if matches!(
                    key.as_str(),
                    "properties" | "patternProperties" | "$defs" | "definitions"
                ) {
                    return child.as_object().is_some_and(|entries| {
                        entries.values().any(contains_encrypted_annotation)
                    });
                }
                contains_encrypted_annotation(child)
            })
        }
        Value::Array(items) => items.iter().any(contains_encrypted_annotation),
        _value => false,
    }
}

// Lowering decodes by value, not by tool plan: every opaque value carries the
// gateway's own versioned prefix, so replayed history decodes correctly even
// when the request resends no tool definitions (for example a Codex local
// compaction request). The plan only selects which output fields to encode.
// The prefix is also the ownership boundary: on a route whose provider owns the
// encrypted fields, an `encrypted_content` part without the gateway prefix is
// provider-owned state and passes through unchanged, while adapter routes fail
// closed because their providers cannot replay it.
fn lower_context(
    context: &mut ResponseContext,
    preserve_provider_content: bool,
) -> Result<(), StreamError> {
    lower_request_value(&mut context.provider_options, preserve_provider_content)?;
    lower_request_value(&mut context.request, preserve_provider_content)
}

fn lower_request_value(
    request: &mut Value,
    preserve_provider_content: bool,
) -> Result<(), StreamError> {
    let Some(input) = request.get_mut("input") else {
        return Ok(());
    };
    lower_input_value(input, preserve_provider_content)
}

fn lower_input_value(
    value: &mut Value,
    preserve_provider_content: bool,
) -> Result<(), StreamError> {
    match value {
        Value::Array(items) => {
            for item in items {
                lower_input_value(item, preserve_provider_content)?;
            }
        }
        Value::Object(map) => {
            if map.get("type").and_then(Value::as_str) == Some("function_call") {
                lower_function_call(map)?;
            }
            for child in map.values_mut() {
                lower_opaque_content_parts(child, preserve_provider_content)?;
            }
        }
        _value => {}
    }
    Ok(())
}

fn lower_function_call(call: &mut Map<String, Value>) -> Result<(), StreamError> {
    let arguments = call
        .get("arguments")
        .map(value_to_string)
        .unwrap_or_default();
    if !contains_opaque_prefix(&arguments) {
        return Ok(());
    }
    if let Some(decoded) = decode_prefixed_arguments(&arguments)? {
        call.insert("arguments".to_string(), json!(decoded));
    }
    Ok(())
}

fn contains_opaque_prefix(text: &str) -> bool {
    text.contains(OPAQUE_CONTENT_PREFIX) || text.contains(LEGACY_CHAT_CONTENT_PREFIX)
}

fn starts_with_opaque_prefix(text: &str) -> bool {
    text.starts_with(OPAQUE_CONTENT_PREFIX) || text.starts_with(LEGACY_CHAT_CONTENT_PREFIX)
}

// The prefix may also appear inside a longer plain value, for example a shell
// command that quotes an opaque blob. Only a whole field value that starts
// with the prefix is gateway-encoded, so anything else stays verbatim.
fn decode_prefixed_arguments(arguments: &str) -> Result<Option<String>, StreamError> {
    let Ok(mut parsed) = sonic_rs::from_str::<Value>(arguments) else {
        return Ok(None);
    };
    let Some(object) = parsed.as_object_mut() else {
        return Ok(None);
    };
    let mut changed = false;
    for (_name, field) in object.iter_mut() {
        let Some(text) = field.as_str() else {
            continue;
        };
        if starts_with_opaque_prefix(text) {
            *field = json!(decode_opaque_content(text)?);
            changed = true;
        }
    }
    if !changed {
        return Ok(None);
    }
    sonic_rs::to_string(&parsed).map(Some).map_err(|_| {
        invalid_tool_arguments_error("AIGateway could not encode decoded tool arguments as JSON")
    })
}

fn lower_opaque_content_parts(
    value: &mut Value,
    preserve_provider_content: bool,
) -> Result<(), StreamError> {
    if value.get("type").and_then(Value::as_str) == Some("encrypted_content") {
        let encoded = value
            .get("encrypted_content")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                invalid_encrypted_content_error(
                    "encrypted_content input parts must contain a string payload",
                )
            })?;
        if preserve_provider_content && !starts_with_opaque_prefix(encoded) {
            return Ok(());
        }
        *value = json!({
            "type": "input_text",
            "text": decode_opaque_content(encoded)?
        });
        return Ok(());
    }

    match value {
        Value::Array(items) => {
            for item in items {
                lower_opaque_content_parts(item, preserve_provider_content)?;
            }
        }
        Value::Object(map) => {
            for child in map.values_mut() {
                lower_opaque_content_parts(child, preserve_provider_content)?;
            }
        }
        _value => {}
    }
    Ok(())
}

fn encode_tool_arguments(
    fields: &BTreeSet<String>,
    arguments: &str,
) -> Result<String, StreamError> {
    let mut arguments = sonic_rs::from_str::<Value>(arguments).map_err(|_| {
        invalid_tool_arguments_error("encrypted tool arguments must be one complete JSON value")
    })?;
    let object = arguments.as_object_mut().ok_or_else(|| {
        invalid_tool_arguments_error("encrypted tool arguments must be a JSON object")
    })?;
    for field in fields {
        let Some(value) = object.get_mut(field) else {
            continue;
        };
        let text = value.as_str().ok_or_else(|| {
            invalid_tool_arguments_error("encrypted tool parameter values must be strings")
        })?;
        *value = json!(encode_opaque_content(text));
    }
    sonic_rs::to_string(&arguments).map_err(|_| {
        invalid_tool_arguments_error("AIGateway could not encode encrypted tool arguments as JSON")
    })
}

fn encode_opaque_content(text: &str) -> String {
    format!(
        "{OPAQUE_CONTENT_PREFIX}{}",
        base64_url_safe_encode(text.as_bytes())
    )
}

fn decode_opaque_content(encoded: &str) -> Result<String, StreamError> {
    let payload = encoded
        .strip_prefix(OPAQUE_CONTENT_PREFIX)
        .or_else(|| encoded.strip_prefix(LEGACY_CHAT_CONTENT_PREFIX))
        .ok_or_else(|| {
            invalid_encrypted_content_error(
                "AIGateway cannot decode encrypted_content from another gateway",
            )
        })?;
    let decoded = base64_url_safe_decode(payload).map_err(|_| {
        invalid_encrypted_content_error("AIGateway encrypted_content is not valid Base64URL")
    })?;
    String::from_utf8(decoded).map_err(|_| {
        invalid_encrypted_content_error("AIGateway encrypted_content is not valid UTF-8")
    })
}

fn call_locator(event: &Value, item: Option<&Value>) -> Option<String> {
    event
        .get("item_id")
        .and_then(Value::as_str)
        .or_else(|| item.and_then(|item| item.get("id").and_then(Value::as_str)))
        .map(|item_id| format!("item:{item_id}"))
        .or_else(|| {
            event
                .get("output_index")
                .and_then(Value::as_u64)
                .map(|index| format!("output:{index}"))
        })
}

fn item_arguments(item: &Value) -> String {
    item.get("arguments")
        .map(value_to_string)
        .unwrap_or_default()
}

fn stream_delta_event(call: &StreamCall, arguments: &str) -> Value {
    let mut event = json!({
        "type": "response.function_call_arguments.delta",
        "delta": arguments
    });
    if let Some(item_id) = &call.item_id {
        event["item_id"] = json!(item_id);
    }
    if let Some(output_index) = call.output_index {
        event["output_index"] = json!(output_index);
    }
    event
}

fn stream_done_event(call: &StreamCall, arguments: &str) -> Value {
    let mut event = json!({
        "type": "response.function_call_arguments.done",
        "arguments": arguments
    });
    if let Some(item_id) = &call.item_id {
        event["item_id"] = json!(item_id);
    }
    if let Some(output_index) = call.output_index {
        event["output_index"] = json!(output_index);
    }
    event
}

fn redact_in_progress_opaque_calls(plan: &ToolFieldPlan, response: &mut Value) {
    let Some(items) = response.get_mut("output").and_then(Value::as_array_mut) else {
        return;
    };
    for item in items {
        if plan.fields_for_item(item).is_some() {
            item["arguments"] = json!("");
        }
    }
}

fn redact_function_call_arguments(response: &mut Value) {
    let Some(items) = response.get_mut("output").and_then(Value::as_array_mut) else {
        return;
    };
    for item in items {
        if item.get("type").and_then(Value::as_str) == Some("function_call") {
            item["arguments"] = json!("");
            item["status"] = json!("incomplete");
        }
    }
}

fn invalid_tool_schema_error(message: impl Into<String>) -> StreamError {
    StreamError::new("invalid_encrypted_tool_schema", "api_resolver", message)
}

fn invalid_tool_arguments_error(message: impl Into<String>) -> StreamError {
    StreamError::new("invalid_encrypted_tool_arguments", "api_resolver", message)
}

fn invalid_encrypted_content_error(message: impl Into<String>) -> StreamError {
    StreamError::new("invalid_encrypted_content", "api_resolver", message)
}

fn missing_call_identity_error() -> StreamError {
    invalid_tool_arguments_error(
        "AIGateway cannot buffer encrypted tool arguments without an item id or output index",
    )
}

fn unstable_call_name_error() -> StreamError {
    invalid_tool_arguments_error(
        "a provider changed the tool name after function arguments entered the public stream",
    )
}

fn ambiguous_tool_schema_error(name: &str) -> StreamError {
    invalid_tool_schema_error(format!(
        "tool name {name} has ambiguous encrypted parameter definitions"
    ))
}
