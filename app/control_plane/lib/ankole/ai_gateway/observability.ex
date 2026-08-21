defmodule Ankole.AIGateway.Observability do
  @moduledoc false

  import Ankole.Observability.Trace,
    only: [
      encode_content: 1,
      map_value: 2,
      mark_error: 2,
      put_present: 3,
      maybe_put_true: 3,
      release: 0,
      safe: 2,
      sanitize: 1,
      text: 1,
      trace_attributes: 1,
      tracer: 0
    ]

  alias Ankole.AIGateway.RequestContext
  alias Ankole.Observability, as: RuntimeObservability
  alias Ankole.Observability.Provider
  alias Ankole.Observability.UserID
  alias OpenTelemetry.Ctx
  alias OpenTelemetry.Span

  @response_span_name "ai_gateway.response"

  defstruct response_span: nil,
            round_span: nil,
            provider: nil,
            round_index: 0,
            round_first_output?: false,
            round_started_at: nil,
            trace_attributes: %{}

  @type t :: %__MODULE__{
          response_span: OpenTelemetry.span_ctx() | nil,
          round_span: OpenTelemetry.span_ctx() | nil,
          provider: Provider.implementation() | nil,
          round_index: non_neg_integer(),
          round_first_output?: boolean(),
          round_started_at: integer() | nil,
          trace_attributes: map()
        }

  @spec start_response(String.t(), map(), keyword()) :: t() | nil
  def start_response(subject_uid, request, opts \\ [])

  def start_response(subject_uid, request, opts)
      when is_binary(subject_uid) and is_map(request) do
    safe(nil, fn -> do_start_response(subject_uid, request, opts) end)
  end

  def start_response(_subject_uid, _request, _opts), do: nil

  @spec start_round(t() | nil, map() | nil, map()) :: t() | nil
  def start_round(nil, _attempt_context, _spec), do: nil

  def start_round(%__MODULE__{} = observation, attempt_context, spec) when is_map(spec) do
    safe(observation, fn -> do_start_round(observation, attempt_context, spec) end)
  end

  def start_round(%__MODULE__{} = observation, _attempt_context, _spec), do: observation

  @spec observe_output(t() | nil, map()) :: t() | nil
  def observe_output(nil, _event), do: nil

  def observe_output(%__MODULE__{round_first_output?: true} = observation, _event),
    do: observation

  def observe_output(%__MODULE__{} = observation, event) when is_map(event) do
    if output_event?(event) do
      safe(observation, fn -> do_mark_first_output(observation) end)
    else
      observation
    end
  end

  def observe_output(%__MODULE__{} = observation, _event), do: observation

  @spec finish_round(t() | nil, map()) :: t() | nil
  def finish_round(nil, _response), do: nil

  def finish_round(%__MODULE__{} = observation, response) when is_map(response) do
    safe(observation, fn -> do_finish_round(observation, response) end)
  end

  def finish_round(%__MODULE__{} = observation, _response), do: observation

  @spec fail_round(t() | nil, term()) :: t() | nil
  def fail_round(nil, _reason), do: nil

  def fail_round(%__MODULE__{} = observation, reason) do
    safe(observation, fn -> fail_open_round(observation, error_type(reason)) end)
  end

  @spec finish_response(t() | nil, term()) :: t() | nil
  def finish_response(nil, _result), do: nil

  def finish_response(%__MODULE__{} = observation, result) do
    safe(observation, fn -> do_finish_response(observation, result) end)
  end

  @spec fail(t() | nil, term()) :: t() | nil
  def fail(nil, _reason), do: nil

  def fail(%__MODULE__{} = observation, reason) do
    safe(observation, fn -> do_fail(observation, reason) end)
  end

  @doc """
  Records one credential-pool retry on the open provider round.
  """
  @spec record_credential_retry(t() | nil, term(), non_neg_integer() | nil) :: :ok
  def record_credential_retry(nil, _reason, _delay_ms), do: :ok

  def record_credential_retry(%__MODULE__{round_span: round_span}, reason, delay_ms) do
    safe(:ok, fn ->
      if recording?(round_span) do
        attributes =
          %{"error.type" => error_type(reason)}
          |> put_present("ankole.ai_gateway.retry_delay_ms", delay_ms)

        Span.add_event(round_span, "ankole.ai_gateway.credential_retry", attributes)
      end

      :ok
    end)
  end

  @doc """
  Records one provider-native compact call as its own root generation.

  `fun` always runs exactly once; tracing failure never changes its result.
  """
  @spec record_compact(String.t() | nil, map(), map(), (-> term())) :: term()
  def record_compact(subject_uid, runtime, request, fun) when is_function(fun, 0) do
    span = safe(nil, fn -> start_compact(subject_uid, runtime, request) end)
    result = fun.()
    safe(:ok, fn -> finish_compact(span, result) end)
    result
  end

  defp do_start_response(subject_uid, request, opts) do
    if provider = RuntimeObservability.provider() do
      request_context = Keyword.get(opts, :request_context) || %{}
      headers = context_headers(opts)
      parent_context = response_parent_context(headers)

      context = %{
        principal_uid: subject_uid,
        principal_type: string_value(Keyword.get(opts, :subject_type)),
        user_id:
          response_user_id(
            subject_uid,
            Keyword.get(opts, :subject_type),
            request_context,
            parent_context
          ),
        actor_event_id: get_in(request, ["metadata", "actor_event_id"]),
        session_id: session_id(request, opts),
        originator: text(Map.get(headers, "originator")),
        caller: string_value(Keyword.get(opts, :caller)),
        release: release(),
        job_id: nil,
        attempts: nil
      }

      trace_attributes =
        context
        |> gateway_trace_attributes()
        |> Map.merge(provider.trace_attributes(context))

      {input, truncated?} = encode_content(request)

      attributes =
        trace_attributes
        |> Map.merge(provider.response_start_attributes(input))
        |> Map.put("ankole.ai_gateway.input", input)
        |> put_present("user_agent.original", text(Map.get(headers, "user-agent")))
        |> put_present("ankole.ai_gateway.client_version", text(Map.get(headers, "version")))
        |> maybe_put_true("ankole.observability.input_truncated", truncated?)

      tracer = tracer()

      response_span =
        :otel_tracer.start_span(parent_context, tracer, @response_span_name, %{
          attributes: attributes,
          kind: :internal
        })

      if recording?(response_span) do
        %__MODULE__{
          response_span: response_span,
          provider: provider,
          trace_attributes: trace_attributes
        }
      else
        nil
      end
    end
  end

  defp do_start_round(observation, attempt_context, spec) do
    observation = finish_replaced_round(observation)
    round_index = observation.round_index + 1
    request = response_context_value(spec, "request") || %{}
    runtime = runtime(attempt_context)
    {input, truncated?} = encode_content(request)
    model = response_context_value(spec, "model")
    model_parameters = model_parameters(request)

    attributes =
      observation.trace_attributes
      |> Map.merge(%{
        "gen_ai.operation.name" => "chat",
        "ankole.ai_gateway.input" => input,
        "ankole.ai_gateway.round" => round_index
      })
      |> Map.merge(
        observation.provider.generation_start_attributes(
          input,
          model,
          model_parameters,
          provider_name(runtime)
        )
      )
      |> put_present("gen_ai.provider.name", provider_name(runtime))
      |> put_present("gen_ai.request.model", model)
      |> put_present("gen_ai.request.max_tokens", map_value(request, "max_output_tokens"))
      |> put_present("gen_ai.request.stream", response_context_value(spec, "stream"))
      |> put_present("gen_ai.request.temperature", map_value(request, "temperature"))
      |> put_present("gen_ai.request.top_p", map_value(request, "top_p"))
      |> put_present("server.address", upstream_host(spec))
      |> put_present("server.port", upstream_port(spec))
      |> put_present("ankole.ai_gateway.provider_kind", map_value(runtime, "provider_kind"))
      |> put_present(
        "ankole.ai_gateway.api_resolver",
        string_value(map_value(spec, "api_resolver"))
      )
      |> maybe_put_true("ankole.observability.input_truncated", truncated?)

    parent_ctx = :otel_tracer.set_current_span(Ctx.new(), observation.response_span)

    round_span =
      :otel_tracer.start_span(
        parent_ctx,
        tracer(),
        generation_span_name(model),
        %{
          attributes: attributes,
          kind: :client
        }
      )

    %{
      observation
      | round_span: round_span,
        round_index: round_index,
        round_first_output?: false,
        round_started_at: System.monotonic_time()
    }
  end

  defp do_mark_first_output(%__MODULE__{round_span: round_span} = observation) do
    if recording?(round_span) do
      Span.set_attributes(round_span, observation.provider.first_output_attributes())

      if is_integer(observation.round_started_at) do
        Span.set_attribute(
          round_span,
          "gen_ai.response.time_to_first_chunk",
          System.convert_time_unit(
            System.monotonic_time() - observation.round_started_at,
            :native,
            :microsecond
          ) / 1_000_000
        )
      end
    end

    %{observation | round_first_output?: true}
  end

  defp do_finish_round(%__MODULE__{round_span: round_span} = observation, response) do
    if recording?(round_span) do
      body = response_body(response)
      {output, truncated?} = encode_content(body)

      attributes =
        %{
          "ankole.ai_gateway.output" => output
        }
        |> Map.merge(observation.provider.output_attributes(output))
        |> Map.merge(usage_attributes(map_value(body, "usage")))
        |> put_present("gen_ai.response.id", map_value(body, "id"))
        |> put_present("gen_ai.response.model", map_value(body, "model"))
        |> maybe_put_true("ankole.observability.output_truncated", truncated?)

      Span.set_attributes(round_span, attributes)
      finish_span(round_span, body)
    end

    %{observation | round_span: nil, round_first_output?: false, round_started_at: nil}
  end

  defp do_finish_response(observation, result) do
    body = response_body(result)

    if recording?(observation.response_span) do
      {output, truncated?} = encode_content(body)

      attributes =
        %{
          "ankole.ai_gateway.output" => output
        }
        |> Map.merge(observation.provider.output_attributes(output))
        |> Map.merge(usage_attributes(map_value(body, "usage")))
        |> put_present("ankole.ai_gateway.response_id", map_value(body, "id"))
        |> maybe_put_true("ankole.observability.output_truncated", truncated?)

      Span.set_attributes(observation.response_span, attributes)
      finish_span(observation.response_span, body)
    end

    %{observation | response_span: nil}
  end

  defp do_fail(observation, reason) do
    error_type = error_type(reason)
    observation = fail_open_round(observation, error_type)

    if recording?(observation.response_span) do
      mark_error(observation.response_span, error_type)
      Span.end_span(observation.response_span)
    end

    %{observation | response_span: nil}
  end

  defp start_compact(subject_uid, runtime, request) do
    if provider = RuntimeObservability.provider() do
      model = map_value(runtime, "model")
      {input, truncated?} = encode_content(request)

      context = %{
        principal_uid: subject_uid,
        principal_type: nil,
        user_id: UserID.principal(subject_uid),
        actor_event_id: nil,
        session_id: nil,
        originator: nil,
        caller: "compaction.upstream",
        release: release(),
        job_id: nil,
        attempts: nil
      }

      attributes =
        context
        |> gateway_trace_attributes()
        |> Map.merge(provider.trace_attributes(context))
        |> Map.merge(
          provider.generation_start_attributes(input, model, nil, provider_name(runtime))
        )
        |> Map.put("ankole.ai_gateway.input", input)
        |> put_present("gen_ai.provider.name", provider_name(runtime))
        |> put_present("gen_ai.request.model", model)
        |> put_present("ankole.ai_gateway.provider_kind", map_value(runtime, "provider_kind"))
        |> maybe_put_true("ankole.observability.input_truncated", truncated?)

      span =
        :otel_tracer.start_span(Ctx.new(), tracer(), compact_span_name(model), %{
          attributes: attributes,
          kind: :client
        })

      if recording?(span) do
        %{span: span, provider: provider}
      end
    end
  end

  defp finish_compact(nil, _result), do: :ok

  defp finish_compact(%{span: span, provider: provider}, result) do
    if recording?(span) do
      body = response_body(result)
      {output, truncated?} = encode_content(body)

      attributes =
        %{"ankole.ai_gateway.output" => output}
        |> Map.merge(provider.output_attributes(output))
        |> Map.merge(usage_attributes(map_value(body, "usage")))
        |> put_present("gen_ai.response.id", map_value(body, "id"))
        |> put_present("gen_ai.response.model", map_value(body, "model"))
        |> maybe_put_true("ankole.observability.output_truncated", truncated?)

      Span.set_attributes(span, attributes)
      finish_span(span, body)
    end

    :ok
  end

  defp compact_span_name(model) when is_binary(model) and model != "", do: "compact #{model}"
  defp compact_span_name(_model), do: "compact"

  defp gateway_trace_attributes(context) do
    context
    |> trace_attributes()
    |> put_present("ankole.ai_gateway.originator", context.originator)
    |> put_present("ankole.ai_gateway.caller", context.caller)
  end

  defp session_id(request, opts) do
    stateful = Keyword.get(opts, :stateful) || %{}

    map_value(stateful, "conversation_id") ||
      RequestContext.session_key(Keyword.get(opts, :request_context) || %{}, request)
  end

  defp context_headers(opts) do
    case Keyword.get(opts, :request_context) do
      %{"headers" => %{} = headers} -> headers
      _context -> %{}
    end
  end

  defp response_parent_context(headers) do
    case text(Map.get(headers, "traceparent")) do
      nil ->
        Ctx.new()

      traceparent ->
        safe(Ctx.new(), fn ->
          context =
            :otel_propagator_text_map.extract_to(
              Ctx.new(),
              :otel_propagator_trace_context,
              [{"traceparent", traceparent}]
            )

          if context |> :otel_tracer.current_span_ctx() |> Span.is_valid() do
            context
          else
            Ctx.new()
          end
        end)
    end
  end

  defp response_user_id(subject_uid, subject_type, request_context, parent_context) do
    case {string_value(subject_type), valid_parent_context?(parent_context),
          RequestContext.observability_user_id(request_context)} do
      {"agent", true, {:ok, user_id}} -> user_id
      _direct_or_untrusted -> UserID.principal(subject_uid)
    end
  end

  defp valid_parent_context?(context) do
    context
    |> :otel_tracer.current_span_ctx()
    |> Span.is_valid()
  end

  defp finish_replaced_round(%__MODULE__{round_span: round_span} = observation) do
    if recording?(round_span) do
      mark_error(round_span, "provider_round_replaced")
      Span.end_span(round_span)
    end

    %{observation | round_span: nil, round_first_output?: false, round_started_at: nil}
  end

  defp fail_open_round(%__MODULE__{round_span: round_span} = observation, error_type) do
    if recording?(round_span) do
      mark_error(round_span, error_type)
      Span.end_span(round_span)
    end

    %{observation | round_span: nil, round_first_output?: false, round_started_at: nil}
  end

  defp finish_span(span, body) do
    case terminal_error_type(body) do
      nil -> Span.set_status(span, OpenTelemetry.status(:ok))
      error_type -> mark_error(span, error_type)
    end

    Span.end_span(span)
  end

  defp terminal_error_type(body) do
    cond do
      is_map(map_value(body, "error")) -> error_type(map_value(body, "error"))
      map_value(body, "status") == "failed" -> "response_failed"
      true -> nil
    end
  end

  defp usage_attributes(usage) when is_map(usage) do
    input_tokens = map_value(usage, "input_tokens") || map_value(usage, "prompt_tokens")
    output_tokens = map_value(usage, "output_tokens") || map_value(usage, "completion_tokens")
    total_tokens = map_value(usage, "total_tokens")
    input_details = map_value(usage, "input_tokens_details")
    cached_tokens = map_value(input_details, "cached_tokens")
    cache_creation_tokens = map_value(input_details, "cache_creation_tokens")

    reasoning_tokens =
      usage |> map_value("output_tokens_details") |> map_value("reasoning_tokens")

    %{}
    |> put_present("gen_ai.usage.input_tokens", input_tokens)
    |> put_present("gen_ai.usage.output_tokens", output_tokens)
    |> put_present("gen_ai.usage.total_tokens", total_tokens)
    |> put_present("gen_ai.usage.cache_read.input_tokens", cached_tokens)
    |> put_present("gen_ai.usage.cache_creation.input_tokens", cache_creation_tokens)
    |> put_present("gen_ai.usage.reasoning.output_tokens", reasoning_tokens)
  end

  defp usage_attributes(_usage), do: %{}

  defp model_parameters(request) when is_map(request) do
    request
    |> Map.take(
      ~w(max_output_tokens parallel_tool_calls reasoning service_tier temperature tool_choice top_p)
    )
    |> encode_map()
  end

  defp model_parameters(_request), do: nil

  defp encode_map(map) when is_map(map) and map_size(map) > 0 do
    case Ankole.JSON.encode(sanitize(map)) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> nil
    end
  end

  defp encode_map(_map), do: nil

  defp response_body({:ok, %{body: %{} = body}}), do: body
  defp response_body(%{body: %{} = body}), do: body
  defp response_body(%{"response" => %{} = body}), do: body
  defp response_body(%{terminal_response: %{} = body}), do: body
  defp response_body(%{} = body), do: body
  defp response_body({:error, reason}), do: %{"status" => "failed", "error" => error_map(reason)}
  defp response_body(reason), do: %{"status" => "failed", "error" => error_map(reason)}

  defp error_map(reason), do: %{"code" => error_type(reason)}

  defp error_type(%{} = error) do
    case map_value(error, "code") do
      code when is_binary(code) and code != "" -> code
      code when is_atom(code) -> Atom.to_string(code)
      _code -> "provider_error"
    end
  end

  defp error_type({tag, %{} = details}) when is_atom(tag) do
    case map_value(details, "code") do
      code when is_binary(code) and code != "" -> code
      code when is_atom(code) -> Atom.to_string(code)
      _code -> Atom.to_string(tag)
    end
  end

  defp error_type({tag, _details}) when is_atom(tag), do: Atom.to_string(tag)
  defp error_type({tag, _one, _two}) when is_atom(tag), do: Atom.to_string(tag)
  defp error_type(tag) when is_atom(tag), do: Atom.to_string(tag)
  defp error_type(_reason), do: "provider_error"

  defp runtime(%{runtime: runtime}) when is_map(runtime), do: runtime
  defp runtime(%{"runtime" => runtime}) when is_map(runtime), do: runtime
  defp runtime(_context), do: %{}

  defp provider_name(runtime) do
    case map_value(runtime, "provider_kind") do
      "azure_openai" -> "azure.ai.openai"
      "chatgpt_subscription" -> "openai"
      "claude" -> "anthropic"
      "google_ai_studio_openai" -> "gcp.gemini"
      provider when is_binary(provider) and provider != "" -> provider
      _provider -> nil
    end
  end

  defp generation_span_name(model) when is_binary(model) and model != "", do: "chat #{model}"
  defp generation_span_name(_model), do: "chat"

  defp output_event?(%{"type" => type}) when is_binary(type) do
    String.starts_with?(type, "response.output_") or
      String.starts_with?(type, "response.reasoning_") or
      type in ["response.content_part.added", "response.content_part.delta"]
  end

  defp output_event?(_event), do: false

  defp response_context_value(spec, key) do
    spec
    |> map_value("response_context")
    |> map_value(key)
  end

  defp upstream_host(spec) do
    with upstream when is_map(upstream) <- map_value(spec, "upstream"),
         url when is_binary(url) <- map_value(upstream, "url"),
         %URI{host: host} when is_binary(host) <- URI.parse(url) do
      host
    else
      _value -> nil
    end
  end

  defp upstream_port(spec) do
    with upstream when is_map(upstream) <- map_value(spec, "upstream"),
         url when is_binary(url) <- map_value(upstream, "url"),
         %URI{scheme: scheme, host: host, port: port} when is_binary(host) <- URI.parse(url) do
      port || URI.default_port(scheme)
    else
      _value -> nil
    end
  end

  defp recording?(nil), do: false
  defp recording?(span), do: Span.is_recording(span)

  defp string_value(nil), do: nil
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value) when is_binary(value), do: value
  defp string_value(_value), do: nil
end
