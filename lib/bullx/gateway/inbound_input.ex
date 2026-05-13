defmodule BullX.Gateway.InboundInput do
  @moduledoc false

  alias BullX.Gateway.{InboundError, JSON, SourceConfig}

  @event_types ~w(message message_edited message_recalled reaction action slash_command trigger)
  @duplex_types @event_types -- ["trigger"]
  @content_kinds ~w(text image audio video file card)
  @routing_fact_key ~r/\A[a-z][a-z0-9_.:-]{0,127}\z/

  @spec normalize(SourceConfig.t(), map()) :: {:ok, map()} | {:error, InboundError.t()}
  def normalize(%SourceConfig{} = source, input) when is_map(input) do
    with {:ok, input} <- stringify_input(input),
         :ok <- validate_input_source(source, input),
         {:ok, occurrence_key} <- occurrence_key(input),
         {:ok, content} <- content(input),
         {:ok, event} <- event(input),
         {:ok, actor} <- actor(input),
         {:ok, scope_id} <- required_string(input, "scope_id"),
         {:ok, thread_id} <- thread_id(input),
         {:ok, refs} <- refs(input),
         {:ok, provenance} <- object(input, "provenance"),
         {:ok, routing_facts} <- routing_facts(input),
         duplex <- event["type"] in @duplex_types,
         {:ok, reply_channel} <- reply_channel(input, source, scope_id, thread_id, duplex) do
      data =
        %{
          "content" => content,
          "event" => event,
          "duplex" => duplex,
          "actor" => actor,
          "scope_id" => scope_id,
          "thread_id" => thread_id,
          "refs" => refs,
          "provenance" => provenance,
          "routing_facts" => routing_facts
        }
        |> maybe_put("reply_channel", reply_channel)

      {:ok,
       %{
         "occurrence_key" => occurrence_key,
         "data" => data,
         "time" => Map.get(input, "time")
       }}
    else
      {:error, %InboundError{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         InboundError.new(:malformed, "invalid inbound input", %{reason: inspect(reason)})}

      _other ->
        {:error, InboundError.new(:malformed, "invalid inbound input")}
    end
  end

  def normalize(_source, _input) do
    {:error, InboundError.new(:adapter_contract, "normalized inbound input must be a map")}
  end

  defp stringify_input(input) do
    case JSON.stringify_keys(input) do
      {:ok, input} ->
        {:ok, input}

      :error ->
        {:error,
         InboundError.new(:adapter_contract, "normalized inbound input is not JSON-neutral")}
    end
  end

  defp validate_input_source(source, input) do
    case {Map.get(input, "adapter"), Map.get(input, "channel_id")} do
      {nil, nil} ->
        :ok

      {adapter, channel_id} when is_binary(adapter) and is_binary(channel_id) ->
        case SourceConfig.canonical_key(source) ==
               SourceConfig.canonical_key({adapter, channel_id}) do
          true ->
            :ok

          false ->
            {:error,
             InboundError.new(
               :adapter_contract,
               "normalized source does not match configured source"
             )}
        end

      _other ->
        {:error, InboundError.new(:adapter_contract, "invalid normalized source identity")}
    end
  end

  defp occurrence_key(input) do
    case Map.get(input, "occurrence_key") || Map.get(input, "bullxoccurkey") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_occurrence_key}
    end
  end

  defp content(input) do
    case Map.fetch(input, "content") do
      {:ok, [_ | _] = blocks} ->
        blocks
        |> Enum.map(&content_block/1)
        |> collect_values(:content)

      _other ->
        {:error, :invalid_content}
    end
  end

  defp content_block(%{} = block) do
    with {:ok, kind} <- required_string(block, "kind"),
         true <- kind in @content_kinds,
         {:ok, body} <- object(block, "body"),
         :ok <- validate_content_body(kind, body) do
      {:ok, %{"kind" => kind, "body" => body}}
    else
      _other -> :error
    end
  end

  defp content_block(_block), do: :error

  defp validate_content_body("text", %{"text" => text}) when is_binary(text) and text != "",
    do: :ok

  defp validate_content_body(kind, %{"fallback_text" => fallback})
       when kind != "text" and is_binary(fallback) and fallback != "" do
    :ok
  end

  defp validate_content_body(_kind, _body), do: :error

  defp event(input) do
    with {:ok, event} <- object(input, "event"),
         {:ok, type} <- required_string(event, "type"),
         true <- type in @event_types,
         {:ok, name} <- required_string(event, "name"),
         {:ok, version} <- positive_integer(event, "version"),
         {:ok, data} <- object(event, "data"),
         :ok <- validate_event_data(type, data) do
      {:ok, %{"type" => type, "name" => name, "version" => version, "data" => data}}
    else
      _other -> {:error, :invalid_event}
    end
  end

  defp validate_event_data(type, data) when type in ~w(message trigger),
    do: validate_json_object(data)

  defp validate_event_data(type, data) when type in ~w(message_edited message_recalled),
    do: required_data(data, ["target_external_id"])

  defp validate_event_data("reaction", data),
    do: required_data(data, ["target_external_id", "emoji", "action"])

  defp validate_event_data("action", data),
    do: required_data(data, ["target_external_id", "action_id", "values"])

  defp validate_event_data("slash_command", data),
    do: required_data(data, ["command_name", "args"])

  defp required_data(data, keys) do
    case Enum.all?(keys, &Map.has_key?(data, &1)) do
      true -> validate_json_object(data)
      false -> :error
    end
  end

  defp validate_json_object(data) do
    case JSON.json_object?(data) do
      true -> :ok
      false -> :error
    end
  end

  defp actor(input) do
    with {:ok, actor} <- object(input, "actor"),
         {:ok, id} <- required_string(actor, "id"),
         {:ok, display} <- required_string(actor, "display"),
         {:ok, bot} <- boolean(actor, "bot") do
      actor =
        actor
        |> Map.put("id", id)
        |> Map.put("display", display)
        |> Map.put("bot", bot)

      {:ok, actor}
    else
      _other -> {:error, :invalid_actor}
    end
  end

  defp thread_id(input) do
    case Map.fetch(input, "thread_id") do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :invalid_thread_id}
    end
  end

  defp refs(input) do
    case Map.get(input, "refs", []) do
      refs when is_list(refs) ->
        refs
        |> Enum.map(&ref/1)
        |> collect_values(:refs)

      _other ->
        {:error, :invalid_refs}
    end
  end

  defp ref(%{} = ref) do
    with {:ok, kind} <- required_string(ref, "kind"),
         {:ok, id} <- required_string(ref, "id") do
      {:ok, ref |> Map.put("kind", kind) |> Map.put("id", id)}
    else
      _other -> :error
    end
  end

  defp ref(_ref), do: :error

  defp routing_facts(input) do
    case Map.get(input, "routing_facts", %{}) do
      %{} = facts ->
        facts
        |> Enum.map(&routing_fact/1)
        |> collect_values(:routing_facts)
        |> case do
          {:ok, pairs} -> {:ok, Map.new(pairs)}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :invalid_routing_facts}
    end
  end

  defp routing_fact({key, value}) when is_binary(key) do
    with true <- Regex.match?(@routing_fact_key, key),
         {:ok, value} <- routing_fact_value(value) do
      {:ok, {key, value}}
    else
      _other -> :error
    end
  end

  defp routing_fact(_pair), do: :error

  defp routing_fact_value(value) when is_binary(value) and value != "", do: {:ok, value}

  defp routing_fact_value([_ | _] = values) do
    case Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      true -> {:ok, values}
      false -> :error
    end
  end

  defp routing_fact_value(_value), do: :error

  defp reply_channel(input, source, scope_id, thread_id, true) do
    with {:ok, reply_channel} <- object(input, "reply_channel"),
         {:ok, adapter} <- required_string(reply_channel, "adapter"),
         {:ok, channel_id} <- required_string(reply_channel, "channel_id"),
         {:ok, reply_scope_id} <- required_string(reply_channel, "scope_id"),
         true <-
           SourceConfig.canonical_key(source) == SourceConfig.canonical_key({adapter, channel_id}),
         true <- reply_scope_id == scope_id,
         true <- Map.get(reply_channel, "thread_id") == thread_id,
         true <- nullable_string?(Map.get(reply_channel, "reply_to_external_id")) do
      {:ok, reply_channel}
    else
      _other -> {:error, :invalid_reply_channel}
    end
  end

  defp reply_channel(_input, _source, _scope_id, _thread_id, false), do: {:ok, nil}

  defp nullable_string?(nil), do: true
  defp nullable_string?(value) when is_binary(value) and value != "", do: true
  defp nullable_string?(_value), do: false

  defp object(input, key) do
    case Map.fetch(input, key) do
      {:ok, value} when is_map(value) -> json_object(value, key)
      _other -> {:error, {:invalid_object, key}}
    end
  end

  defp json_object(value, key) do
    case JSON.json_object?(value) do
      true -> {:ok, value}
      false -> {:error, {:invalid_json_object, key}}
    end
  end

  defp required_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:required_string, key}}
    end
  end

  defp boolean(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _other -> {:error, {:required_boolean, key}}
    end
  end

  defp positive_integer(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {:positive_integer, key}}
    end
  end

  defp collect_values(values, reason) do
    case Enum.all?(values, &match?({:ok, _value}, &1)) do
      true -> {:ok, Enum.map(values, fn {:ok, value} -> value end)}
      false -> {:error, {:invalid_list, reason}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
