defmodule Ankole.Logging do
  @moduledoc """
  Small control-plane logging facade aligned with the Bun worker logger API.

  Callers provide a stable event name, a human message, and structured fields.
  The JSON formatter promotes reserved metadata keys and leaves ordinary
  high-cardinality fields in the log payload.
  """

  require Logger

  @type fields :: map() | keyword()

  @spec debug(String.t() | atom(), String.t(), fields()) :: :ok
  def debug(event, message, fields \\ %{}), do: log(:debug, event, message, fields)

  @spec info(String.t() | atom(), String.t(), fields()) :: :ok
  def info(event, message, fields \\ %{}), do: log(:info, event, message, fields)

  @spec notice(String.t() | atom(), String.t(), fields()) :: :ok
  def notice(event, message, fields \\ %{}), do: log(:notice, event, message, fields)

  @spec warning(String.t() | atom(), String.t(), fields()) :: :ok
  def warning(event, message, fields \\ %{}), do: log(:warning, event, message, fields)

  @spec error(String.t() | atom(), String.t(), fields()) :: :ok
  def error(event, message, fields \\ %{}), do: log(:error, event, message, fields)

  @spec critical(String.t() | atom(), String.t(), fields()) :: :ok
  def critical(event, message, fields \\ %{}), do: log(:critical, event, message, fields)

  @spec alert(String.t() | atom(), String.t(), fields()) :: :ok
  def alert(event, message, fields \\ %{}), do: log(:alert, event, message, fields)

  @spec emergency(String.t() | atom(), String.t(), fields()) :: :ok
  def emergency(event, message, fields \\ %{}), do: log(:emergency, event, message, fields)

  defp log(level, event, message, fields) do
    Logger.log(level, message, metadata(event, fields))
  end

  defp metadata(event, fields) do
    {metadata, payload} =
      fields
      |> Enum.reduce({[event: event_name(event)], %{}}, &put_field/2)

    if map_size(payload) == 0 do
      metadata
    else
      [{:payload, payload} | metadata]
    end
  end

  defp put_field({key, value}, {metadata, payload}) when is_atom(key) do
    {[{key, value} | metadata], payload}
  end

  defp put_field({key, value}, {metadata, payload}) when is_binary(key) do
    case special_metadata_key(key) do
      nil -> {metadata, Map.put(payload, key, value)}
      metadata_key -> {[{metadata_key, value} | metadata], payload}
    end
  end

  defp put_field({key, value}, {metadata, payload}) do
    {metadata, Map.put(payload, inspect(key), value)}
  end

  defp event_name(value) when is_atom(value), do: Atom.to_string(value)
  defp event_name(value) when is_binary(value), do: value
  defp event_name(value), do: inspect(value)

  defp special_metadata_key("labels"), do: :labels
  defp special_metadata_key("operation"), do: :operation
  defp special_metadata_key("insert_id"), do: :insert_id
  defp special_metadata_key("trace"), do: :trace
  defp special_metadata_key("span_id"), do: :span_id
  defp special_metadata_key("trace_sampled"), do: :trace_sampled
  defp special_metadata_key("http_request"), do: :http_request
  defp special_metadata_key(_key), do: nil
end
