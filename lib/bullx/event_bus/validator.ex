defmodule BullX.EventBus.Validator do
  @moduledoc false

  alias BullX.EventBus.InvalidEvent

  @required_top_level ["specversion", "id", "source", "type", "time", "datacontenttype", "data"]
  @required_data [
    "content",
    "channel",
    "scope",
    "actor",
    "refs",
    "reply_channel",
    "routing_facts",
    "raw_ref"
  ]
  @routing_fact_key ~r/\A[a-z][a-z0-9_]*\z/

  @spec validate(term()) :: {:ok, map()} | {:error, InvalidEvent.t()}
  def validate(%{} = event) do
    with :ok <- json_neutral_string_keyed(event, []),
         :ok <- require_top_level(event),
         :ok <- validate_top_level(event),
         :ok <- validate_data(event["data"]) do
      {:ok, event}
    end
  end

  def validate(_event) do
    {:error,
     invalid(
       :not_json_neutral,
       [],
       "event must be a decoded string-keyed JSON object"
     )}
  end

  defp require_top_level(event) do
    missing = Enum.find(@required_top_level, &(not Map.has_key?(event, &1)))

    case missing do
      nil ->
        :ok

      key ->
        {:error,
         invalid(:missing_required_attribute, [key], "missing required CloudEvents attribute")}
    end
  end

  defp validate_top_level(event) do
    with :ok <- require_non_empty_string(event, "specversion"),
         :ok <- require_non_empty_string(event, "id"),
         :ok <- require_non_empty_string(event, "source"),
         :ok <- require_non_empty_string(event, "type"),
         :ok <- require_non_empty_string(event, "time"),
         :ok <- validate_specversion(event),
         :ok <- validate_datacontenttype(event),
         :ok <- validate_time(event) do
      :ok
    end
  end

  defp validate_specversion(%{"specversion" => "1.0"}), do: :ok

  defp validate_specversion(_event) do
    {:error, invalid(:invalid_specversion, ["specversion"], "specversion must be 1.0")}
  end

  defp validate_datacontenttype(%{"datacontenttype" => "application/json"}), do: :ok

  defp validate_datacontenttype(_event) do
    {:error,
     invalid(
       :invalid_datacontenttype,
       ["datacontenttype"],
       "datacontenttype must be application/json"
     )}
  end

  defp validate_time(%{"time" => time}) do
    case DateTime.from_iso8601(time) do
      {:ok, _dt, _offset} ->
        :ok

      {:error, _reason} ->
        {:error, invalid(:invalid_payload_shape, ["time"], "time must be RFC3339")}
    end
  end

  defp validate_data(data) when is_map(data) do
    with :ok <- require_data_fields(data),
         :ok <- validate_content(data["content"]),
         :ok <- validate_channel(data["channel"]),
         :ok <- validate_scope(data["scope"]),
         :ok <- validate_actor(data["actor"]),
         :ok <- validate_refs(data["refs"]),
         :ok <- validate_reply_channel(data["reply_channel"]),
         :ok <- validate_routing_facts(data["routing_facts"]),
         :ok <- validate_raw_ref(data["raw_ref"]) do
      :ok
    end
  end

  defp validate_data(_data) do
    {:error, invalid(:invalid_payload_shape, ["data"], "data must be an object")}
  end

  defp require_data_fields(data) do
    missing = Enum.find(@required_data, &(not Map.has_key?(data, &1)))

    case missing do
      nil ->
        :ok

      key ->
        {:error,
         invalid(:missing_required_attribute, ["data", key], "missing required data field")}
    end
  end

  defp validate_content([_ | _] = content) do
    content
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {block, index}, :ok ->
      case validate_content_block(block, index) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_content(_content) do
    {:error,
     invalid(:invalid_payload_shape, ["data", "content"], "content must be a non-empty list")}
  end

  defp validate_content_block(%{"kind" => kind, "body" => body}, _index)
       when is_binary(kind) and kind != "" and is_map(body),
       do: :ok

  defp validate_content_block(_block, index) do
    {:error,
     invalid(
       :invalid_payload_shape,
       ["data", "content", index],
       "content block must contain non-empty kind and object body"
     )}
  end

  defp validate_channel(%{"adapter" => adapter, "id" => id})
       when is_binary(adapter) and adapter != "" and is_binary(id) and id != "",
       do: :ok

  defp validate_channel(_channel) do
    {:error,
     invalid(
       :invalid_payload_shape,
       ["data", "channel"],
       "channel.adapter and channel.id must be non-empty strings"
     )}
  end

  defp validate_scope(%{"id" => id, "thread_id" => thread_id})
       when is_binary(id) and id != "" and (is_binary(thread_id) or is_nil(thread_id)),
       do: :ok

  defp validate_scope(_scope) do
    {:error,
     invalid(
       :invalid_payload_shape,
       ["data", "scope"],
       "scope.id must be non-empty and scope.thread_id must be string or null"
     )}
  end

  defp validate_actor(%{
         "id" => id,
         "display" => display,
         "bot" => bot,
         "principal_ref" => principal_ref
       })
       when is_binary(id) and id != "" and (is_binary(display) or is_nil(display)) and
              is_boolean(bot) and (is_binary(principal_ref) or is_nil(principal_ref)),
       do: :ok

  defp validate_actor(_actor) do
    {:error, invalid(:invalid_payload_shape, ["data", "actor"], "actor shape is invalid")}
  end

  defp validate_refs(refs) when is_list(refs) do
    refs
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {ref, index}, :ok ->
      case ref do
        %{"kind" => kind, "id" => id}
        when is_binary(kind) and kind != "" and is_binary(id) and id != "" ->
          {:cont, :ok}

        _ref ->
          {:halt,
           {:error,
            invalid(
              :invalid_payload_shape,
              ["data", "refs", index],
              "reference requires kind and id"
            )}}
      end
    end)
  end

  defp validate_refs(_refs) do
    {:error, invalid(:invalid_payload_shape, ["data", "refs"], "refs must be a list")}
  end

  defp validate_reply_channel(nil), do: :ok
  defp validate_reply_channel(%{}), do: :ok

  defp validate_reply_channel(_reply_channel) do
    {:error,
     invalid(
       :invalid_payload_shape,
       ["data", "reply_channel"],
       "reply_channel must be object or null"
     )}
  end

  defp validate_routing_facts(%{} = facts) do
    facts
    |> Map.keys()
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case Regex.match?(@routing_fact_key, key) do
        true ->
          {:cont, :ok}

        false ->
          {:halt,
           {:error,
            invalid(
              :invalid_payload_shape,
              ["data", "routing_facts", key],
              "invalid routing_facts key"
            )}}
      end
    end)
  end

  defp validate_routing_facts(_facts) do
    {:error,
     invalid(:invalid_payload_shape, ["data", "routing_facts"], "routing_facts must be an object")}
  end

  defp validate_raw_ref(nil), do: :ok

  defp validate_raw_ref(%{"kind" => kind, "id" => id})
       when is_binary(kind) and kind != "" and is_binary(id) and id != "",
       do: :ok

  defp validate_raw_ref(_raw_ref) do
    {:error,
     invalid(
       :invalid_payload_shape,
       ["data", "raw_ref"],
       "raw_ref must be null or a reference object with kind and id"
     )}
  end

  defp require_non_empty_string(event, key) do
    case Map.fetch(event, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        :ok

      _other ->
        {:error, invalid(:missing_required_attribute, [key], "#{key} must be a non-empty string")}
    end
  end

  defp json_neutral_string_keyed(nil, _path), do: :ok
  defp json_neutral_string_keyed(value, _path) when is_boolean(value), do: :ok
  defp json_neutral_string_keyed(value, _path) when is_integer(value), do: :ok

  defp json_neutral_string_keyed(value, path) when is_float(value) do
    case finite_float?(value) do
      true -> :ok
      false -> {:error, invalid(:not_json_neutral, path, "float must be finite")}
    end
  end

  defp json_neutral_string_keyed(value, path) when is_binary(value) do
    case String.contains?(value, <<0>>) do
      true -> {:error, invalid(:nul_string, path, "strings must not contain NUL")}
      false -> :ok
    end
  end

  defp json_neutral_string_keyed(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {element, index}, :ok ->
      case json_neutral_string_keyed(element, path ++ [index]) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp json_neutral_string_keyed(%_struct{}, path) do
    {:error, invalid(:not_json_neutral, path, "structs are not JSON-neutral")}
  end

  defp json_neutral_string_keyed(value, path) when is_map(value) do
    value
    |> Enum.reduce_while(:ok, fn {key, val}, :ok ->
      case key do
        key when is_binary(key) ->
          case json_neutral_string_keyed(val, path ++ [key]) do
            :ok -> {:cont, :ok}
            {:error, error} -> {:halt, {:error, error}}
          end

        _key ->
          {:halt, {:error, invalid(:not_json_neutral, path, "object keys must be strings")}}
      end
    end)
  end

  defp json_neutral_string_keyed(_value, path) do
    {:error, invalid(:not_json_neutral, path, "value is not JSON-neutral")}
  end

  defp finite_float?(value), do: value == value and value not in [:infinity, :negative_infinity]

  defp invalid(code, path, message, details \\ %{}) do
    %InvalidEvent{code: code, path: path, message: message, details: details}
  end
end
