defmodule Ankole.Observability do
  @moduledoc """
  Optional OpenTelemetry trace export configured through AppConfigure.

  OpenTelemetry records and exports process-wide traces. The selected Provider
  adds the vendor semantics needed for AIGateway and Worker spans; it does not
  own transport or filter other spans.
  """

  use GenServer

  import Ankole.Observability.Trace,
    only: [
      encode_content: 1,
      map_value: 2,
      mark_error: 2,
      put_present: 3,
      maybe_put_true: 3,
      release: 0,
      safe: 2,
      text: 1,
      trace_attributes: 1,
      tracer: 0
    ]

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema
  alias Ankole.Logging
  alias Ankole.Observability.Provider
  alias Ankole.Observability.UserID
  alias Ankole.Signals.Signal
  alias Ankole.Sessions.TurnRuntimeEnv
  alias OpenTelemetry.Ctx
  alias OpenTelemetry.Span

  @enabled_key "observability.traces.enabled"
  @provider_key "observability.traces.provider"
  @endpoint_key "observability.traces.otlp_endpoint"
  @headers_key "observability.traces.otlp_headers"
  @runtime_key {__MODULE__, :provider}
  @runtime_config_key {__MODULE__, :runtime_config}
  @worker_export_timeout_ms 10_000
  @direct_message_types ~w(conversation.message.addressed im.message.may_intervene)
  @otlp_environment_variables ~w(
    OTEL_EXPORTER_OTLP_COMPRESSION
    OTEL_EXPORTER_OTLP_ENDPOINT
    OTEL_EXPORTER_OTLP_HEADERS
    OTEL_EXPORTER_OTLP_PROTOCOL
    OTEL_EXPORTER_OTLP_TRACES_COMPRESSION
    OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
    OTEL_EXPORTER_OTLP_TRACES_HEADERS
    OTEL_EXPORTER_OTLP_TRACES_PROTOCOL
    OTEL_TRACES_EXPORTER
  )

  @type runtime_config ::
          :disabled
          | %{
              provider: Provider.implementation(),
              endpoint: String.t(),
              headers: [{String.t(), String.t()}]
            }

  @doc """
  Starts the owner that configures the process-wide OTLP exporter.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the semantic provider for this control-plane boot.
  """
  @spec provider() :: Provider.implementation() | nil
  def provider, do: :persistent_term.get(@runtime_key, nil)

  @doc "Compares the saved settings with this process's attempted and applied boot configuration."
  def configuration_status do
    if Process.whereis(__MODULE__),
      do:
        GenServer.call(__MODULE__, {:configuration_status, config_fingerprint(runtime_config())}),
      else: "unknown"
  end

  defp config_fingerprint(config), do: :crypto.hash(:sha256, :erlang.term_to_binary(config))

  def validate_settings(read) do
    with {:ok, enabled} <- read.(@enabled_key) do
      if enabled do
        with {:ok, provider} when is_binary(provider) <- read.(@provider_key),
             {:ok, endpoint} when is_binary(endpoint) <- read.(@endpoint_key),
             {:ok, _headers} <- read.(@headers_key),
             do: :ok,
             else: (_ -> {:error, :incomplete_trace_configuration})
      else
        :ok
      end
    end
  end

  if Mix.env() == :test do
    @doc false
    @spec put_provider_for_test(Provider.implementation() | nil) :: :ok
    def put_provider_for_test(provider) when is_atom(provider) or is_nil(provider),
      do: set_provider(provider)

    @doc false
    @spec put_runtime_config_for_test(runtime_config() | nil) :: :ok
    def put_runtime_config_for_test(config), do: set_runtime_config(config)
  end

  @doc """
  Starts one attempt's root span. The caller owns the returned handle.

  A tracing failure returns `nil` and does not change turn delivery.
  """
  @spec start_turn(Signal.t(), map()) ::
          map() | nil
  def start_turn(%Signal{} = signal, %{} = turn_start_spec) do
    if provider(), do: safe(nil, fn -> start_turn_span(signal, turn_start_spec) end)
  end

  def start_turn(_signal, _turn_start_spec), do: nil

  @doc "Measures a bounded domain stage using identity and outcome facts only."
  def stage(name, attributes, fun, parent \\ nil) do
    span =
      if provider(),
        do:
          safe(nil, fn ->
            context =
              case parent do
                %{span: span} -> :otel_tracer.set_current_span(Ctx.new(), span)
                _ -> Ctx.new()
              end

            :otel_tracer.start_span(context, tracer(), name, %{
              attributes: attributes,
              kind: :internal
            })
          end)

    try do
      result = fun.()
      finish_stage(span, result)
      result
    catch
      kind, reason ->
        finish_stage(span, {:error, :exception})
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc "Returns already loaded Signal identities without a storage lookup."
  def signal_attributes(signal) do
    %{
      "ankole.tenant.id" => signal.tenant_id,
      "ankole.principal.uid" => signal.agent_uid,
      "session.id" => signal.session_id,
      "ankole.signal.id" => signal.id,
      "ankole.signal.source_event_id" => signal.source_event_id,
      "ankole.session.attempt" => signal.attempt_count
    }
  end

  defp finish_stage(nil, _result), do: :ok

  defp finish_stage(span, result) do
    safe(:ok, fn ->
      {status, fields} = stage_result(result)
      Span.set_attributes(span, Map.put(fields, "ankole.stage.outcome", status))
      if status == "error", do: mark_error(span, "stage_failed")
      Span.end_span(span)
    end)
  end

  defp stage_result({:ok, %Signal{} = signal}), do: {"ok", signal_attributes(signal)}

  defp stage_result({:ok, %{event: %Signal{} = signal, epoch: epoch}}),
    do: {"admitted", Map.put(signal_attributes(signal), "ankole.session.epoch", epoch)}

  defp stage_result({:ok, {phase, %Ankole.Conversations.Delivery.Intent{} = intent, _, _}}),
    do:
      {to_string(phase),
       %{
         "ankole.signal.id" => intent.source_signal_id,
         "ankole.delivery.attempt" => intent.attempt_count
       }}

  defp stage_result({:ok, %{status: status}}), do: {to_string(status), %{}}
  defp stage_result({:error, _}), do: {"error", %{}}
  defp stage_result({:unknown, _}), do: {"unknown", %{}}
  defp stage_result(:unknown), do: {"unknown", %{}}
  defp stage_result({:stale, _}), do: {"stale", %{}}
  defp stage_result(:stale), do: {"stale", %{}}
  defp stage_result(_), do: {"ok", %{}}

  @doc "Starts an execution's turn span and attaches its request trace context."
  @spec attach_turn(map()) :: map()
  def attach_turn(%{span: nil} = execution) do
    request_context =
      Map.merge(execution.spec.request_context, %{
        "signal_id" => execution.signal_id,
        "session_epoch" => execution.epoch,
        "session_attempt" => execution.event.attempt_count
      })

    execution = %{execution | spec: Map.put(execution.spec, :request_context, request_context)}
    span = start_turn(execution.event, execution.spec)

    context =
      if span,
        do:
          Map.merge(execution.spec.request_context, %{
            "traceparent" => span.traceparent,
            "observability_user_id" => span.user_id
          }),
        else: execution.spec.request_context

    %{execution | span: span, spec: Map.put(execution.spec, :request_context, context)}
  end

  def attach_turn(execution), do: execution

  @doc """
  Ends the attempt span outside the domain transaction.
  """
  @spec finish_turn(map() | nil, keyword()) :: :ok
  def finish_turn(handle, opts \\ [])

  def finish_turn(%{span: _, provider: _} = handle, opts) when is_list(opts) do
    safe(:ok, fn -> finish_turn_span(handle, opts) end)
  end

  def finish_turn(_handle, _opts), do: :ok

  @doc "Starts a tool span under the attempt root."
  def start_tool(%{span: parent, provider: provider} = handle, call) do
    safe(nil, fn ->
      {input, truncated?} = encode_content(call["arguments"] || call["input"])

      attributes =
        handle.attributes
        |> Map.merge(%{
          "gen_ai.operation.name" => "execute_tool",
          "gen_ai.tool.name" => call["name"],
          "gen_ai.tool.call.id" => call["call_id"] || call["id"],
          "gen_ai.tool.call.arguments" => input
        })
        |> maybe_put_true("ankole.observability.input_truncated", truncated?)

      context = :otel_tracer.set_current_span(Ctx.new(), parent)

      span =
        :otel_tracer.start_span(context, tracer(), "execute_tool #{call["name"]}", %{
          attributes: attributes,
          kind: :internal
        })

      %{span: span, provider: provider}
    end)
  end

  def start_tool(_handle, _call), do: nil

  @doc "Ends a tool span when its result arrives."
  def finish_tool(%{span: span}, result) do
    safe(:ok, fn ->
      {output, truncated?} = encode_content(result)

      Span.set_attributes(
        span,
        maybe_put_true(
          %{"gen_ai.tool.call.result" => output},
          "ankole.observability.output_truncated",
          truncated?
        )
      )

      if result["is_error"],
        do: mark_error(span, result["failure_kind"] || "tool_error"),
        else: Span.set_status(span, OpenTelemetry.status(:ok))

      Span.end_span(span)
      :ok
    end)
  end

  def finish_tool(_handle, _result), do: :ok

  @doc """
  Forwards one worker-produced OTLP protobuf request through the configured exporter endpoint.

  Disabled tracing drops the request and returns `:ok`.
  """
  @spec export_worker_spans(binary()) ::
          :ok | {:error, :invalid_otlp_payload | :otlp_export_failed}
  def export_worker_spans(payload) when is_binary(payload) and byte_size(payload) > 0 do
    safe({:error, :otlp_export_failed}, fn -> do_export_worker_spans(payload) end)
  end

  def export_worker_spans(_payload), do: {:error, :invalid_otlp_payload}

  @doc """
  Returns the AppConfigure definitions owned by observability.
  """
  @spec definitions() :: [Definition.t()]
  def definitions do
    [enabled_definition(), provider_definition(), endpoint_definition(), headers_definition()]
  end

  @doc false
  @spec runtime_config() :: {:ok, runtime_config()} | {:error, term()}
  def runtime_config do
    with {:ok, enabled?} <- AppConfigure.get(enabled_definition()) do
      if enabled? do
        load_enabled_config()
      else
        {:ok, :disabled}
      end
    end
  end

  @impl true
  def init(opts) do
    set_provider(nil)
    set_runtime_config(nil)
    set_exporter = Keyword.get(opts, :set_exporter, &set_exporter/1)

    attempted = runtime_config()

    enabled? =
      case attempted do
        {:ok, :disabled} ->
          false

        {:ok, config} ->
          case set_exporter.(config) do
            :ok ->
              Logging.info(
                "observability.traces.configured",
                "OpenTelemetry trace export configured",
                %{otlp_host: endpoint_host(config.endpoint)}
              )

              set_provider(config.provider)
              set_runtime_config(config)
              true

            {:error, reason} ->
              log_disabled(reason)
              false
          end

        {:error, reason} ->
          log_disabled(reason)
          false
      end

    {:ok,
     %{
       enabled?: enabled?,
       attempted: config_fingerprint(attempted),
       disabled?: attempted == {:ok, :disabled}
     }}
  end

  @impl true
  def handle_call({:configuration_status, desired}, _from, state) do
    status =
      cond do
        desired != state.attempted -> "pending_restart"
        state.enabled? or state.disabled? -> "applied"
        true -> "failed"
      end

    {:reply, status, state}
  end

  @impl true
  def terminate(_reason, %{enabled?: true}) do
    _ = :otel_tracer_provider.force_flush()
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_turn_span(%Signal{} = signal, turn_start_spec) do
    provider = provider()
    request_context = map_value(turn_start_spec, "request_context") || %{}
    user_id = turn_user_id(signal, turn_start_spec)
    {input, truncated?} = encode_content(Signal.envelope(signal))

    context =
      %{
        principal_uid: signal.agent_uid,
        principal_type: "agent",
        user_id: user_id,
        signal_id: signal.id,
        session_attempt: signal.attempt_count,
        session_epoch: map_value(request_context, "session_epoch"),
        session_id: signal.session_id,
        originator: nil,
        caller: "sessions.turn",
        release: release(),
        job_id: positive_integer(map_value(request_context, "job_id")),
        attempts: positive_integer(map_value(request_context, "attempts"))
      }
      |> Ankole.Observability.Trace.with_tenant()

    attributes =
      context
      |> turn_trace_attributes()
      |> Map.merge(provider.trace_attributes(context))
      |> Map.merge(provider.turn_start_attributes(input))
      |> maybe_put_true("ankole.observability.input_truncated", truncated?)

    span =
      :otel_tracer.start_span(Ctx.new(), tracer(), turn_span_name(signal.type), %{
        attributes: attributes,
        kind: :internal
      })

    if Span.is_recording(span) do
      case traceparent(span) do
        traceparent when is_binary(traceparent) ->
          %{
            span: span,
            provider: provider,
            traceparent: traceparent,
            user_id: user_id,
            attributes: turn_trace_attributes(context)
          }

        nil ->
          mark_error(span, "trace_context_injection_failed")
          Span.end_span(span)
          nil
      end
    end
  end

  defp finish_turn_span(%{span: span, provider: provider}, opts) do
    if Span.is_recording(span) do
      outcome = text(Keyword.get(opts, :outcome))
      output = Keyword.get(opts, :output) || if(outcome, do: %{"outcome" => outcome})

      case output do
        nil ->
          :ok

        output ->
          {encoded, truncated?} = encode_content(output)

          attributes =
            provider.output_attributes(encoded, :turn)
            |> maybe_put_true("ankole.observability.output_truncated", truncated?)

          Span.set_attributes(span, attributes)
      end

      case text(Keyword.get(opts, :error_type)) do
        nil -> Span.set_status(span, OpenTelemetry.status(:ok))
        error_type -> mark_error(span, error_type)
      end

      Span.end_span(span)
    end

    :ok
  end

  defp traceparent(span) do
    context = :otel_tracer.set_current_span(Ctx.new(), span)

    context
    |> :otel_propagator_text_map.inject_from(:otel_propagator_trace_context, [])
    |> Enum.find_value(fn
      {key, value} when key in ["traceparent", <<"traceparent">>] and is_binary(value) -> value
      _header -> nil
    end)
  end

  defp turn_user_id(%Signal{} = signal, turn_start_spec) do
    runtime_env = map_value(turn_start_spec, "runtime_env") || %{}
    principal_uid = TurnRuntimeEnv.current_sender_principal_uid(runtime_env)
    channel_id = text(signal.conversation_id)

    cond do
      direct_human_message?(signal) and is_binary(principal_uid) ->
        UserID.principal(principal_uid)

      is_binary(channel_id) ->
        UserID.channel(channel_id)

      is_binary(principal_uid) ->
        UserID.principal(principal_uid)

      true ->
        nil
    end
  end

  defp direct_human_message?(%Signal{
         type: type,
         source_event_id: source_event_id,
         data: data
       })
       when type in @direct_message_types and is_map(data) do
    get_in(data, ["channel", "kind"]) == "im_dm" and
      not retry_source_event?(source_event_id)
  end

  defp direct_human_message?(%Signal{}), do: false

  defp retry_source_event?("retry:" <> _rest), do: true
  defp retry_source_event?(_source_event_id), do: false

  defp turn_trace_attributes(context) do
    context
    |> trace_attributes()
    |> Map.put("gen_ai.operation.name", "invoke_agent")
    |> put_present("ankole.session.attempt", context.session_attempt)
    |> put_present("ankole.session.epoch", context.session_epoch)
    |> put_present("ankole.background_agent_job.id", context.job_id)
    |> put_present("ankole.background_agent_job.attempts", context.attempts)
  end

  defp turn_span_name(type) when is_binary(type) and type != "", do: "turn #{type}"
  defp turn_span_name(_type), do: "turn unknown"

  defp do_export_worker_spans(payload) do
    case :persistent_term.get(@runtime_config_key, nil) do
      %{provider: provider, endpoint: endpoint, headers: headers} ->
        headers =
          headers
          |> Enum.reject(fn {name, _value} -> String.downcase(name) == "content-type" end)
          |> List.insert_at(0, {"content-type", "application/x-protobuf"})

        with {:ok, payload} <- provider.map_worker_spans(payload) do
          case Req.request(
                 method: :post,
                 url: endpoint <> "/v1/traces",
                 headers: headers,
                 body: payload,
                 retry: false,
                 redirect: false,
                 receive_timeout: @worker_export_timeout_ms
               ) do
            {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
            {:ok, %Req.Response{}} -> {:error, :otlp_export_failed}
            {:error, _reason} -> {:error, :otlp_export_failed}
          end
        end

      _disabled ->
        :ok
    end
  end

  defp enabled_definition do
    AppConfigure.define(
      key: @enabled_key,
      scope: :global,
      encrypted: false,
      schema: Schema.boolean(),
      default_value: false,
      description:
        "When true, the control plane exports process-wide OpenTelemetry traces to the configured OTLP endpoint after restart."
    )
  end

  defp endpoint_definition do
    AppConfigure.define(
      key: @endpoint_key,
      scope: :global,
      encrypted: false,
      schema: endpoint_schema(),
      description:
        "Base OTLP HTTP endpoint for traces. The exporter appends /v1/traces. Required when trace export is enabled."
    )
  end

  defp provider_definition do
    AppConfigure.define(
      key: @provider_key,
      scope: :global,
      encrypted: false,
      schema: Schema.enum(Provider.values()),
      description:
        "Semantic provider for LLM traces: langfuse, langsmith, or opentelemetry. Required when trace export is enabled."
    )
  end

  defp headers_definition do
    AppConfigure.define(
      key: @headers_key,
      scope: :global,
      encrypted: true,
      schema: headers_schema(),
      default_value: %{},
      description:
        "Secret HTTP headers for OTLP trace export, such as Authorization. Values take effect after restart."
    )
  end

  defp load_enabled_config do
    with {:ok, provider_name} <-
           required_value(provider_definition(), :missing_trace_provider),
         {:ok, provider} <- fetch_provider(provider_name),
         {:ok, endpoint} <- required_value(endpoint_definition(), :missing_otlp_endpoint),
         {:ok, headers} <- AppConfigure.get(headers_definition()) do
      {:ok, %{provider: provider, endpoint: endpoint, headers: headers |> Enum.sort()}}
    end
  end

  defp fetch_provider(name) do
    case Provider.fetch(name) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, :unsupported_trace_provider}
    end
  end

  defp required_value(definition, missing_reason) do
    case AppConfigure.get(definition) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, missing_reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp endpoint_schema do
    Schema.new(fn
      endpoint when is_binary(endpoint) ->
        endpoint = String.trim_trailing(String.trim(endpoint), "/")

        case URI.parse(endpoint) do
          %URI{
            scheme: scheme,
            host: host,
            path: path,
            userinfo: nil,
            query: nil,
            fragment: nil
          }
          when scheme in ["http", "https"] and is_binary(host) and host != "" ->
            if trace_signal_path?(path) do
              {:error, :trace_signal_path_not_allowed}
            else
              {:ok, endpoint}
            end

          _uri ->
            {:error, :not_http_endpoint}
        end

      _endpoint ->
        {:error, :not_http_endpoint}
    end)
  end

  defp trace_signal_path?(path) when is_binary(path),
    do: String.ends_with?(String.downcase(path), "/v1/traces")

  defp trace_signal_path?(_path), do: false

  defp headers_schema do
    Schema.new(fn
      headers when is_map(headers) ->
        if Enum.all?(headers, &valid_header?/1) do
          {:ok, headers}
        else
          {:error, :not_string_headers}
        end

      _headers ->
        {:error, :not_string_headers}
    end)
  end

  defp valid_header?({name, value}),
    do: is_binary(name) and name != "" and is_binary(value)

  defp set_exporter(%{endpoint: endpoint, headers: headers}) do
    # AppConfigure is the only owner of trace export. The upstream exporter
    # otherwise gives standard OTLP environment variables higher precedence
    # than the explicit endpoint and headers passed here.
    Enum.each(@otlp_environment_variables, &System.delete_env/1)

    exporter_config = %{
      endpoints: [endpoint],
      headers: headers,
      protocol: :http_protobuf
    }

    try do
      case :otel_batch_processor.set_exporter(
             :global,
             :opentelemetry_exporter,
             exporter_config
           ) do
        :ok -> :ok
        other -> {:error, {:unexpected_exporter_result, other}}
      end
    rescue
      error -> {:error, {:exporter_exception, error.__struct__}}
    catch
      :exit, reason -> {:error, {:exporter_exit, reason}}
    end
  end

  defp set_provider(nil) do
    :persistent_term.put(@runtime_key, nil)
    :ok
  end

  defp set_provider(provider) do
    :persistent_term.put(@runtime_key, provider)
    :ok
  end

  defp set_runtime_config(:disabled), do: set_runtime_config(nil)

  defp set_runtime_config(config) do
    :persistent_term.put(@runtime_config_key, config)
    :ok
  end

  defp endpoint_host(endpoint) do
    case URI.parse(endpoint) do
      %URI{host: host} when is_binary(host) -> host
      _uri -> nil
    end
  end

  defp log_disabled(reason) do
    Logging.warning(
      "observability.traces.disabled",
      "OpenTelemetry trace export remains disabled",
      %{reason: safe_reason(reason)}
    )
  end

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason({tag, _details}) when is_atom(tag), do: Atom.to_string(tag)
  defp safe_reason(_reason), do: "configuration_error"

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil
end
