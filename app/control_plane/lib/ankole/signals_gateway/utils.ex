defmodule Ankole.SignalsGateway.Utils do
  @moduledoc false

  def signal_session_id(signal_channel_id), do: "signal-channel:#{signal_channel_id}"

  def maybe_put_result(result, _key, nil), do: result
  def maybe_put_result(result, key, value), do: Map.put(result, key, value)

  def min_datetime(%DateTime{} = left, %DateTime{} = right) do
    case DateTime.compare(left, right) do
      :gt -> right
      _other -> left
    end
  end

  def datetime_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  def datetime_iso8601(_value), do: nil

  def thread_key(nil), do: ""
  def thread_key(value) when is_binary(value), do: value
  def thread_key(value), do: to_string(value)

  def unthread_key(""), do: nil
  def unthread_key(value), do: value

  def parse_datetime(nil), do: nil

  def parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  def parse_datetime(%DateTime{} = value), do: value
  def parse_datetime(_value), do: nil

  def text_length(text) when is_binary(text), do: String.length(text)
  def text_length(_text), do: 0

  def digest(parts) do
    parts
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  def collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  def normalize_provider_lifecycle_kind(nil), do: nil

  def normalize_provider_lifecycle_kind(kind) when is_atom(kind) do
    kind
    |> Atom.to_string()
    |> normalize_provider_lifecycle_kind()
  end

  def normalize_provider_lifecycle_kind(kind) when is_binary(kind) do
    case String.trim(kind) do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_provider_lifecycle_kind(_kind), do: nil

  def normalize_agent_uid_attr(%{agent_uid: agent_uid} = attrs) when is_binary(agent_uid) do
    %{attrs | agent_uid: normalize_uid(agent_uid)}
  end

  def normalize_agent_uid_attr(attrs), do: attrs

  def fetch_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  def fetch_value(_map, _key), do: nil

  def fetch_map(map, key, default) do
    case fetch_value(map, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  def fetch_list(map, key) do
    case fetch_value(map, key) do
      value when is_list(value) -> value
      nil -> []
      value -> [value]
    end
  end

  def required_text(map, key) do
    case optional_text(map, key) do
      nil -> {:error, {:missing_required_text, key}}
      value -> {:ok, value}
    end
  end

  def optional_text(map, key) when is_map(map) do
    case fetch_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      nil ->
        nil

      value when is_atom(value) ->
        Atom.to_string(value)

      value when is_integer(value) ->
        Integer.to_string(value)

      _value ->
        nil
    end
  end

  def optional_text(_map, _key), do: nil

  def fetch_datetime(map, key) do
    case fetch_value(map, key) do
      %DateTime{} = datetime -> datetime
      _value -> nil
    end
  end

  def normalize_channel_kind(value) when value in [:im_dm, "im_dm"], do: :im_dm
  def normalize_channel_kind(value) when value in [:im_group, "im_group"], do: :im_group

  def normalize_channel_kind(value) when value in [:webhook_endpoint, "webhook_endpoint"],
    do: :webhook_endpoint

  def normalize_channel_kind(value) when value in [:issue, "issue"], do: :issue

  def normalize_channel_kind(value) when value in [:alert_stream, "alert_stream"],
    do: :alert_stream

  def normalize_channel_kind(_value), do: :unknown

  def normalize_reply_mode(value) when value in [:channel, "channel"], do: :channel
  def normalize_reply_mode(value) when value in [:entry, "entry"], do: :entry
  def normalize_reply_mode(_value), do: :none

  def normalize_reaction_action(value) when value in [:remove, "remove", :deleted, "deleted"],
    do: :remove

  def normalize_reaction_action(_value), do: :add

  def truthy?(value) when value in [true, "true", 1, "1"], do: true
  def truthy?(_value), do: false

  def normalize_uid(uid) when is_binary(uid), do: uid |> String.trim() |> String.downcase()
  def normalize_uid(uid), do: uid

  def update_enum_text(map, key) do
    case fetch_value(map, key) do
      value when is_atom(value) -> Map.put(map, key, Atom.to_string(value))
      _value -> map
    end
  end

  def structured_mention?(mention, agent_uid) when is_map(mention) do
    structured? =
      truthy?(fetch_value(mention, :structured)) ||
        fetch_value(mention, :kind) in [:agent, "agent", :bot, "bot"]

    mentioned_agent = optional_text(mention, :agent_uid)
    structured? and (is_nil(mentioned_agent) or normalize_uid(mentioned_agent) == agent_uid)
  end

  def structured_mention?(_mention, _agent_uid), do: false
end
