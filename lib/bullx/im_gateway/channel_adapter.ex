defmodule BullX.IMGateway.ChannelAdapter do
  @moduledoc """
  Common trusted plugin channel adapter contract.

  IM-style adapters declare `im_listen_modes: [:addressed_only, :all_messages]`
  in `capabilities/0` and honor a per-source `im_listen_mode` for transport
  admission. The adapter normalizes provider input to CloudEvents and hands it
  to `BullX.IMGateway`.
  """

  alias BullX.Plugins.Extension
  alias BullX.IMGateway.DeliveryCircuitBreaker

  @extension_point :"bullx.im_gateway.channel_adapter"
  @adapter_id ~r/\A[a-z][a-z0-9_]*\z/

  @callback normalize_inbound(source :: map(), provider_input :: term()) ::
              {:ok, decoded_cloud_event :: map()}
              | :ignore
              | {:error, safe_error :: map()}

  @callback deliver(source :: map(), reply_address :: map(), outbound :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, safe_error :: map()}

  @callback fetch_source(source_id :: String.t()) :: {:ok, map()} | {:error, term()}

  @callback consume_stream(
              source :: map(),
              reply_address :: map(),
              stream_id :: String.t(),
              opts :: keyword()
            ) ::
              :ok | {:error, safe_error :: map()}

  @callback capabilities() :: map()

  @optional_callbacks capabilities: 0, deliver: 4, consume_stream: 4, fetch_source: 1

  @type accept_result :: {:ok, term()} | :ignore | {:error, term()}

  @spec extension_point() :: atom()
  def extension_point, do: @extension_point

  @spec enabled_adapters(GenServer.server()) :: {:ok, [Extension.t()]} | {:error, term()}
  def enabled_adapters(server \\ BullX.Plugins.Registry) do
    @extension_point
    |> BullX.Plugins.enabled_extensions_for(server)
    |> validate_extensions()
  end

  @spec fetch_enabled_adapter(String.t() | atom(), GenServer.server()) ::
          {:ok, Extension.t()} | {:error, :not_found | term()}
  def fetch_enabled_adapter(adapter_id, server \\ BullX.Plugins.Registry) do
    id = normalize_id(adapter_id)

    with {:ok, adapters} <- enabled_adapters(server) do
      case Enum.find(adapters, &(normalize_id(&1.id) == id)) do
        nil -> {:error, :not_found}
        extension -> {:ok, extension}
      end
    end
  end

  @spec deliver(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def deliver(reply_address, outbound, opts \\ [])
      when is_map(reply_address) and is_map(outbound) and is_list(opts) do
    registry = Keyword.get(opts, :registry, configured_registry())

    with {:ok, adapter_id} <- reply_address_value(reply_address, "adapter"),
         {:ok, source_id} <- reply_address_value(reply_address, "channel_id"),
         {:ok, extension} <- fetch_enabled_adapter(adapter_id, registry),
         :ok <- ensure_callback(extension.module, :deliver, 4),
         :ok <- ensure_callback(extension.module, :fetch_source, 1),
         {:ok, source} <- extension.module.fetch_source(source_id) do
      adapter_opts =
        opts
        |> Keyword.delete(:registry)
        |> Keyword.delete(:delivery_circuit_breaker)

      DeliveryCircuitBreaker.run(
        {normalize_id(adapter_id), source_id(source) || source_id},
        fn -> extension.module.deliver(source, reply_address, outbound, adapter_opts) end,
        Keyword.get(opts, :delivery_circuit_breaker, [])
      )
    end
  end

  @spec consume_stream(map(), String.t(), keyword()) :: :ok | {:error, term()}
  def consume_stream(reply_address, stream_id, opts \\ [])
      when is_map(reply_address) and is_binary(stream_id) and is_list(opts) do
    registry = Keyword.get(opts, :registry, configured_registry())

    with {:ok, adapter_id} <- reply_address_value(reply_address, "adapter"),
         {:ok, source_id} <- reply_address_value(reply_address, "channel_id"),
         {:ok, extension} <- fetch_enabled_adapter(adapter_id, registry),
         :ok <- ensure_callback(extension.module, :consume_stream, 4),
         :ok <- ensure_callback(extension.module, :fetch_source, 1),
         {:ok, source} <- extension.module.fetch_source(source_id) do
      extension.module.consume_stream(
        source,
        reply_address,
        stream_id,
        Keyword.delete(opts, :registry)
      )
    end
  end

  @spec accept_inbound(String.t() | atom(), map(), term(), keyword()) :: accept_result()
  def accept_inbound(adapter_id, source, provider_input, opts \\ [])
      when is_map(source) and is_list(opts) do
    registry = Keyword.get(opts, :registry, BullX.Plugins.Registry)
    im_gateway_opts = Keyword.delete(opts, :registry)
    metadata = %{adapter_id: normalize_id(adapter_id), source_id: source_id(source)}

    emit([:event, :received], %{}, metadata)

    with {:ok, extension} <- fetch_enabled_adapter(adapter_id, registry),
         metadata <- Map.merge(metadata, extension_metadata(extension)),
         {:ok, event} <- normalize(extension.module, source, provider_input),
         :ok <- validate_event_adapter(extension, event) do
      emit([:event, :normalized], %{}, Map.put(metadata, :event_type, event["type"]))
      accept_event(extension, event, im_gateway_opts, metadata)
    else
      :ignore ->
        emit([:event, :ignored], %{}, Map.put(metadata, :diagnostic_code, :ignored))
        :ignore

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec build_cloud_event(map()) :: {:ok, map()} | {:error, map()}
  def build_cloud_event(attrs) when is_map(attrs) do
    data = Map.fetch!(attrs, :data)

    event = %{
      "specversion" => "1.0",
      "id" => Map.fetch!(attrs, :id),
      "source" => Map.fetch!(attrs, :source),
      "type" => Map.fetch!(attrs, :type),
      "time" => Map.fetch!(attrs, :time),
      "datacontenttype" => "application/json",
      "data" => normalize_payload(data)
    }

    {:ok, maybe_put_subject(event, Map.get(attrs, :subject))}
  rescue
    KeyError -> {:error, %{"kind" => "invalid_cloud_event_attrs"}}
  end

  defp normalize(module, source, provider_input) do
    case module.normalize_inbound(source, provider_input) do
      {:ok, %{} = event} ->
        {:ok, event}

      :ignore ->
        :ignore

      {:error, %{} = error} ->
        {:error, error}

      other ->
        {:error, %{"kind" => "invalid_adapter_return", "value" => inspect(other, limit: 3)}}
    end
  end

  defp configured_registry do
    Application.get_env(:bullx, :im_gateway_channel_adapter_registry, BullX.Plugins.Registry)
  end

  defp reply_address_value(reply_address, key) do
    case map_value(reply_address, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:invalid_reply_address, key}}
    end
  end

  defp ensure_callback(module, function, arity) do
    case function_exported?(module, function, arity) do
      true -> :ok
      false -> {:error, {:adapter_callback_missing, module, function, arity}}
    end
  end

  defp validate_extensions(extensions) do
    extensions
    |> Enum.reduce_while({:ok, []}, fn extension, {:ok, acc} ->
      case valid_extension?(extension) do
        true -> {:cont, {:ok, [extension | acc]}}
        false -> {:halt, {:error, {:invalid_channel_adapter, extension.id, extension.module}}}
      end
    end)
    |> case do
      {:ok, adapters} -> {:ok, Enum.reverse(adapters)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_extension?(%Extension{id: id, module: module}) do
    valid_adapter_id?(normalize_id(id)) and Code.ensure_loaded?(module) and
      function_exported?(module, :normalize_inbound, 2)
  end

  defp normalize_id(id) when is_atom(id), do: Atom.to_string(id)
  defp normalize_id(id) when is_binary(id), do: id

  defp valid_adapter_id?(id) when is_binary(id), do: Regex.match?(@adapter_id, id)

  # Adapters are trusted code but `normalize_inbound/2` returns user-influenced
  # data — refuse to accept an Event whose `channel.adapter` doesn't match the
  # adapter we just invoked. Otherwise a misbehaving or compromised adapter
  # could mint Events that appear to come from a different adapter and reach
  # rules scoped to it.
  defp validate_event_adapter(%Extension{} = extension, event) do
    expected = normalize_id(extension.id)

    case get_in(event, ["data", "channel", "adapter"]) do
      ^expected ->
        :ok

      actual ->
        {:error,
         %{
           "kind" => "adapter_id_mismatch",
           "expected_adapter" => expected,
           "actual_adapter" => actual
         }}
    end
  end

  defp accept_event(%Extension{} = extension, event, opts, metadata) do
    accept_metadata =
      metadata
      |> Map.merge(extension_metadata(extension))
      |> Map.put(:event_type, event["type"])

    emit([:event, :accept, :start], %{}, accept_metadata)

    try do
      result = BullX.IMGateway.accept_cloud_event(event, opts)

      emit(
        [:event, :accept, :stop],
        %{},
        Map.put(accept_metadata, :status, accept_status(result))
      )

      result
    rescue
      exception ->
        emit([:event, :accept, :exception], %{}, %{
          adapter_id: normalize_id(extension.id),
          plugin_id: extension.plugin_id,
          reason: exception.__struct__
        })

        reraise exception, __STACKTRACE__
    end
  end

  defp extension_metadata(%Extension{} = extension) do
    %{adapter_id: normalize_id(extension.id), plugin_id: extension.plugin_id}
  end

  defp source_id(%{"id" => id}) when is_binary(id), do: id
  defp source_id(%{id: id}) when is_binary(id), do: id
  defp source_id(%{"source" => source}) when is_binary(source), do: source
  defp source_id(_source), do: nil

  defp accept_status({:ok, %{status: status}}), do: status
  defp accept_status({:ok, _result}), do: :accepted
  defp accept_status({:error, reason}) when is_atom(reason), do: reason
  defp accept_status({:error, %{code: code}}), do: code
  defp accept_status(_result), do: :error

  defp emit(path, measurements, metadata) do
    :telemetry.execute([:bullx, :im_gateway, :adapter | path], measurements, metadata)
  end

  defp map_value(%{} = map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp normalize_payload(data) do
    %{
      "content" => stringify_value(Map.fetch!(data, :content)),
      "channel" => stringify_keys(Map.fetch!(data, :channel)),
      "scope" => stringify_keys(Map.fetch!(data, :scope)),
      "actor" => stringify_keys(Map.fetch!(data, :actor)),
      "refs" => stringify_value(Map.get(data, :refs, [])),
      "reply_address" => maybe_stringify_map(Map.get(data, :reply_address)),
      "routing_facts" => stringify_keys(Map.get(data, :routing_facts, %{})),
      "raw_ref" => stringify_value(Map.get(data, :raw_ref))
    }
  end

  defp maybe_put_subject(event, nil), do: event

  defp maybe_put_subject(event, subject) when is_binary(subject),
    do: Map.put(event, "subject", subject)

  defp maybe_stringify_map(nil), do: nil
  defp maybe_stringify_map(%{} = map), do: stringify_keys(map)

  defp stringify_keys(%{} = map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} when is_binary(key) -> {key, stringify_value(value)}
    end)
  end

  defp stringify_value(%{} = map), do: stringify_keys(map)
  defp stringify_value(values) when is_list(values), do: Enum.map(values, &stringify_value/1)
  defp stringify_value(value), do: value
end
