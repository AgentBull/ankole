defmodule Ankole.Observability do
  @moduledoc """
  Optional OpenTelemetry trace export configured through AppConfigure.

  OpenTelemetry records and exports process-wide traces. The selected Provider
  adds the vendor semantics needed for AIGateway LLM spans; it does not own
  transport or filter other spans.
  """

  use GenServer

  import Ankole.Observability.Trace,
    only: [
      encode_content: 1,
      map_value: 2,
      mark_error: 2,
      maybe_put: 3,
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
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.TurnRuntimeEnv
  alias OpenTelemetry.Ctx
  alias OpenTelemetry.Span

  @enabled_key "observability.traces.enabled"
  @provider_key "observability.traces.provider"
  @endpoint_key "observability.traces.otlp_endpoint"
  @headers_key "observability.traces.otlp_headers"
  @runtime_key {__MODULE__, :provider}
  @runtime_config_key {__MODULE__, :runtime_config}
  @turn_table :ankole_observability_turn_spans
  @turn_cleanup_interval_ms :timer.minutes(1)
  # Worker turns end within minutes under stall detection; a day-old open
  # entry means the terminal was lost, so the sweep can close it visibly.
  @turn_span_timeout_ms :timer.hours(24)
  @worker_export_timeout_ms 10_000
  @direct_message_types ~w(im.message.addressed im.message.may_intervene)
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

  @doc false
  @spec put_provider_for_test(Provider.implementation() | nil) :: :ok
  def put_provider_for_test(provider) when is_atom(provider) or is_nil(provider),
    do: set_provider(provider)

  @doc false
  @spec put_runtime_config_for_test(runtime_config() | nil) :: :ok
  def put_runtime_config_for_test(config), do: set_runtime_config(config)

  @doc """
  Starts the root span for one persisted TurnStart and returns its trace context.

  A tracing failure returns `nil` and does not change turn delivery.
  """
  @spec start_turn(ActorEvent.t(), map()) ::
          %{traceparent: String.t(), user_id: String.t() | nil} | nil
  def start_turn(%ActorEvent{} = actor_event, %{} = turn_start_spec) do
    if provider() && :ets.whereis(@turn_table) != :undefined do
      safe(nil, fn ->
        finish_registered_turn(actor_event.id, error_type: "turn_replaced")
        start_turn_span(actor_event, turn_start_spec)
      end)
    end
  end

  def start_turn(_actor_event, _turn_start_spec), do: nil

  @doc """
  Ends one registered turn root outside the terminal database transaction.
  """
  @spec finish_turn(String.t(), keyword()) :: :ok
  def finish_turn(actor_event_id, opts \\ [])

  def finish_turn(actor_event_id, opts) when is_binary(actor_event_id) and is_list(opts) do
    safe(:ok, fn -> finish_registered_turn(actor_event_id, opts) end)
  end

  def finish_turn(_actor_event_id, _opts), do: :ok

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

  @doc """
  Registers the observability AppConfigure keys.
  """
  @spec ensure_registered() :: :ok | {:error, term()}
  def ensure_registered do
    Enum.reduce_while(definitions(), :ok, fn definition, :ok ->
      case AppConfigure.register_definitions([definition]) do
        :ok -> {:cont, :ok}
        {:error, {:duplicate_key, key}} when key == definition.key -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc false
  @spec runtime_config() :: {:ok, runtime_config()} | {:error, term()}
  def runtime_config do
    with :ok <- ensure_registered(),
         {:ok, enabled?} <- AppConfigure.get(enabled_definition()) do
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
    ensure_turn_table()
    set_exporter = Keyword.get(opts, :set_exporter, &set_exporter/1)

    enabled? =
      case runtime_config() do
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

    state = %{
      enabled?: enabled?,
      turn_cleanup_interval_ms:
        Keyword.get(opts, :turn_cleanup_interval_ms, @turn_cleanup_interval_ms),
      turn_span_timeout_ms: Keyword.get(opts, :turn_span_timeout_ms, @turn_span_timeout_ms)
    }

    if Process.whereis(__MODULE__) == self() do
      schedule_turn_cleanup(state.turn_cleanup_interval_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:cleanup_turn_spans, state) do
    safe(:ok, fn ->
      cleanup_turn_spans(System.monotonic_time(:millisecond), state.turn_span_timeout_ms)
    end)

    schedule_turn_cleanup(state.turn_cleanup_interval_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{enabled?: true}) do
    finish_all_turns("turn_outcome_lost")
    _ = :otel_tracer_provider.force_flush()
    :ok
  end

  def terminate(_reason, _state) do
    finish_all_turns("turn_outcome_lost")
    :ok
  end

  defp start_turn_span(%ActorEvent{} = actor_event, turn_start_spec) do
    provider = provider()
    request_context = map_value(turn_start_spec, "request_context") || %{}
    user_id = turn_user_id(actor_event, turn_start_spec)
    {input, truncated?} = encode_content(actor_event.payload)

    context = %{
      principal_uid: actor_event.agent_uid,
      principal_type: "agent",
      user_id: user_id,
      actor_event_id: actor_event.id,
      session_id: actor_event.session_id,
      originator: nil,
      caller: "signals_gateway.turn",
      release: release(),
      job_id: positive_integer(map_value(request_context, "job_id")),
      attempts: positive_integer(map_value(request_context, "attempts"))
    }

    attributes =
      context
      |> turn_trace_attributes()
      |> Map.merge(provider.trace_attributes(context))
      |> Map.merge(provider.turn_start_attributes(input))
      |> Map.put("ankole.turn.input", input)
      |> maybe_put_true("ankole.observability.input_truncated", truncated?)

    span =
      :otel_tracer.start_span(Ctx.new(), tracer(), turn_span_name(actor_event.type), %{
        attributes: attributes,
        kind: :internal
      })

    if Span.is_recording(span) do
      case traceparent(span) do
        traceparent when is_binary(traceparent) ->
          true =
            :ets.insert(
              @turn_table,
              {actor_event.id,
               %{
                 span: span,
                 provider: provider,
                 started_at_ms: System.monotonic_time(:millisecond)
               }}
            )

          %{traceparent: traceparent, user_id: user_id}

        nil ->
          mark_error(span, "trace_context_injection_failed")
          Span.end_span(span)
          nil
      end
    end
  end

  defp finish_registered_turn(actor_event_id, opts) do
    case :ets.take(@turn_table, actor_event_id) do
      [{^actor_event_id, entry}] -> finish_turn_span(entry, opts)
      [] -> :ok
    end
  end

  defp finish_turn_span(%{span: span, provider: provider}, opts) do
    if Span.is_recording(span) do
      case Keyword.get(opts, :output) do
        output when is_binary(output) ->
          {encoded, truncated?} = encode_content(output)

          attributes =
            %{"ankole.turn.output" => encoded}
            |> Map.merge(provider.output_attributes(encoded))
            |> maybe_put_true("ankole.observability.output_truncated", truncated?)

          Span.set_attributes(span, attributes)

        _output ->
          :ok
      end

      case text(Keyword.get(opts, :error_type)) do
        nil -> Span.set_status(span, OpenTelemetry.status(:ok))
        error_type -> mark_error(span, error_type)
      end

      Span.end_span(span)
    end

    :ok
  end

  defp cleanup_turn_spans(now_ms, timeout_ms) do
    Enum.each(:ets.tab2list(@turn_table), fn
      {actor_event_id, %{started_at_ms: started_at_ms}}
      when now_ms - started_at_ms >= timeout_ms ->
        finish_registered_turn(actor_event_id, error_type: "turn_outcome_lost")

      _entry ->
        :ok
    end)
  end

  defp finish_all_turns(error_type) do
    case :ets.whereis(@turn_table) do
      :undefined ->
        :ok

      _table ->
        Enum.each(:ets.tab2list(@turn_table), fn {actor_event_id, _entry} ->
          safe(:ok, fn -> finish_registered_turn(actor_event_id, error_type: error_type) end)
        end)
    end
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

  defp turn_user_id(%ActorEvent{} = actor_event, turn_start_spec) do
    runtime_env = map_value(turn_start_spec, "runtime_env") || %{}
    principal_uid = TurnRuntimeEnv.current_sender_principal_uid(runtime_env)
    channel_id = text(actor_event.signal_channel_id)

    cond do
      direct_human_message?(actor_event) and is_binary(principal_uid) ->
        UserID.principal(principal_uid)

      is_binary(channel_id) ->
        UserID.channel(channel_id)

      is_binary(principal_uid) ->
        UserID.principal(principal_uid)

      true ->
        nil
    end
  end

  defp direct_human_message?(%ActorEvent{
         type: type,
         source_event_id: source_event_id,
         payload: payload
       })
       when type in @direct_message_types and is_map(payload) do
    get_in(payload, ["data", "channel", "kind"]) == "im_dm" and
      not retry_source_event?(source_event_id)
  end

  defp direct_human_message?(%ActorEvent{}), do: false

  defp retry_source_event?("retry:" <> _rest), do: true
  defp retry_source_event?(_source_event_id), do: false

  defp turn_trace_attributes(context) do
    context
    |> trace_attributes()
    |> maybe_put("ankole.background_agent_job.id", context.job_id)
    |> maybe_put("ankole.background_agent_job.attempts", context.attempts)
  end

  defp turn_span_name(type) when is_binary(type) and type != "", do: "turn #{type}"
  defp turn_span_name(_type), do: "turn unknown"

  defp ensure_turn_table do
    case :ets.whereis(@turn_table) do
      :undefined ->
        :ets.new(@turn_table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

        :ok

      _table ->
        :ok
    end
  end

  defp schedule_turn_cleanup(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :cleanup_turn_spans, interval_ms)
    :ok
  end

  defp do_export_worker_spans(payload) do
    case :persistent_term.get(@runtime_config_key, nil) do
      %{endpoint: endpoint, headers: headers} ->
        headers =
          headers
          |> Enum.reject(fn {name, _value} -> String.downcase(name) == "content-type" end)
          |> List.insert_at(0, {"content-type", "application/x-protobuf"})

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
