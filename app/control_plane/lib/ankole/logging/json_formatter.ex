defmodule Ankole.Logging.JSONFormatter do
  @moduledoc """
  Formats Elixir/Erlang Logger events as Ankole structured JSON.

  The formatter writes one JSON object per line through the standard Logger
  handler. Docker and Kubernetes collectors can ingest those lines without an
  Ankole-specific sidecar or remote logging API.
  """

  @behaviour :logger_formatter

  @internal_metadata_keys MapSet.new([
                            "time",
                            "pid",
                            "gl",
                            "mfa",
                            "module",
                            "function",
                            "file",
                            "line",
                            "domain",
                            "report_cb",
                            "erl_level",
                            "application",
                            "ancestors",
                            "callers",
                            "initial_call",
                            "registered_name",
                            "process_label",
                            "crash_reason",
                            "ansi_color"
                          ])

  @special_metadata_keys MapSet.new([
                           "event",
                           "labels",
                           "operation",
                           "http_request",
                           "insert_id",
                           "trace",
                           "span_id",
                           "trace_sampled",
                           "payload"
                         ])

  @reserved_payload_keys [
    "severity",
    "level",
    "severity_text",
    "severity_number",
    "message",
    "time",
    "event",
    "labels",
    "operation",
    "http_request",
    "insert_id",
    "trace",
    "span_id",
    "trace_sampled",
    "httpRequest"
  ]

  @impl true
  def check_config(_config), do: :ok

  @impl true
  def format(%{level: level, msg: message, meta: metadata}, config) do
    metadata = metadata_map(metadata)

    entry =
      %{
        "severity" => severity(level),
        "message" => message_to_string(message),
        "time" => timestamp(metadata),
        "event" => event(metadata),
        "labels" => labels(metadata, config)
      }
      |> put_payload(metadata)
      |> put_promoted(metadata, :operation, "operation")
      |> put_promoted(metadata, :http_request, "http_request")
      |> put_promoted(metadata, :insert_id, "insert_id")
      |> put_promoted(metadata, :trace, "trace")
      |> put_promoted(metadata, :span_id, "span_id")
      |> put_promoted(metadata, :trace_sampled, "trace_sampled")

    [Ankole.JSON.encode!(entry), "\n"]
  rescue
    _error ->
      ~s({"severity":"ERROR","message":"failed to format log entry","event":"logger.formatter_failed"}\n)
  end

  defp severity(:debug), do: "DEBUG"
  defp severity(:info), do: "INFO"
  defp severity(:notice), do: "NOTICE"
  defp severity(:warning), do: "WARNING"
  defp severity(:error), do: "ERROR"
  defp severity(:critical), do: "CRITICAL"
  defp severity(:alert), do: "ALERT"
  defp severity(:emergency), do: "EMERGENCY"
  defp severity(_level), do: "INFO"

  defp message_to_string({:string, chardata}), do: IO.iodata_to_binary(chardata)
  defp message_to_string({:report, report}), do: inspect(report)

  defp message_to_string({format, args}) when is_list(args) do
    format
    |> :io_lib.format(args)
    |> IO.iodata_to_binary()
  rescue
    _error -> inspect({format, args})
  end

  defp message_to_string(chardata) when is_binary(chardata) or is_list(chardata),
    do: IO.iodata_to_binary(chardata)

  defp message_to_string(message), do: inspect(message)

  defp timestamp(metadata) do
    metadata
    |> metadata_get(:time)
    |> timestamp_value()
  end

  defp timestamp_value(value) when is_integer(value) and value > 1_000_000_000_000_000 do
    value
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp timestamp_value(value) when is_integer(value) and value > 1_000_000_000_000 do
    value
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp timestamp_value(value) when is_integer(value) and value > 0 do
    value
    |> DateTime.from_unix!(:second)
    |> DateTime.to_iso8601()
  end

  defp timestamp_value(_value), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp event(metadata) do
    metadata
    |> metadata_get(:event)
    |> event_value()
  end

  defp event_value(nil), do: "logger.message"
  defp event_value(value) when is_atom(value), do: Atom.to_string(value)
  defp event_value(value) when is_binary(value), do: value
  defp event_value(value), do: inspect(value)

  defp labels(metadata, config) do
    default_labels(config)
    |> Map.merge(label_map(metadata_get(metadata, :labels)))
  end

  defp default_labels(config) do
    config
    |> config_get(:labels, %{})
    |> label_map()
    |> Map.merge(
      label_map(%{
        "service" => "ankole-control-plane",
        "component" => "control-plane",
        "runtime" => "beam",
        "environment" => System.get_env("ANKOLE_ENV") || config_get(config, :environment, nil),
        "version" => System.get_env("ANKOLE_VERSION") || config_get(config, :version, nil)
      })
    )
  end

  defp label_map(value) when is_map(value) or is_list(value) do
    value
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      if value in [nil, ""] do
        acc
      else
        Map.put(acc, string_key(key), to_string(value))
      end
    end)
  end

  defp label_map(_value), do: %{}

  defp put_payload(entry, metadata) do
    payload =
      metadata
      |> metadata_payload()
      |> Map.merge(payload_field(metadata_get(metadata, :payload)))
      |> drop_reserved_payload()

    Map.merge(entry, payload)
  end

  defp metadata_payload(metadata) do
    metadata
    |> Enum.reject(fn {key, _value} -> ignored_metadata_key?(key) end)
    |> Map.new(fn {key, value} -> {string_key(key), json_safe(value)} end)
  end

  defp payload_field(value) when is_map(value) or is_list(value) do
    value
    |> Enum.reject(fn {key, value} -> is_nil(value) or reserved_payload_key?(key) end)
    |> Map.new(fn {key, value} -> {string_key(key), json_safe(value)} end)
  end

  defp payload_field(_value), do: %{}

  defp drop_reserved_payload(payload) do
    Map.reject(payload, fn {key, _value} -> reserved_payload_key?(key) end)
  end

  defp put_promoted(entry, metadata, metadata_key, json_key) do
    case metadata_get(metadata, metadata_key) || Map.get(metadata, json_key) do
      nil -> entry
      value -> Map.put(entry, json_key, json_safe(value))
    end
  end

  defp ignored_metadata_key?(key) do
    name = metadata_key_name(key)

    google_metadata_key?(name) or MapSet.member?(@internal_metadata_keys, name) or
      MapSet.member?(@special_metadata_keys, name)
  end

  defp metadata_get(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_map(metadata) when is_map(metadata), do: metadata
  defp metadata_map(metadata) when is_list(metadata), do: Map.new(metadata)
  defp metadata_map(_metadata), do: %{}

  defp config_get(config, key, default) when is_map(config) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key)) || default
  end

  defp config_get(config, key, default) when is_list(config),
    do: Keyword.get(config, key, default)

  defp config_get(_config, _key, default), do: default

  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_safe(%Date{} = value), do: Date.to_iso8601(value)
  defp json_safe(%Time{} = value), do: Time.to_iso8601(value)

  defp json_safe(%{__exception__: true} = error) do
    %{
      "type" => error.__struct__ |> Module.split() |> List.last(),
      "message" => Exception.message(error)
    }
  end

  defp json_safe(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value

  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)

  defp json_safe(value)
       when is_pid(value) or is_port(value) or is_reference(value) or is_function(value),
       do: inspect(value)

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  defp json_safe(%_struct{} = value), do: inspect(value)

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {string_key(key), json_safe(value)} end)
  end

  defp json_safe(value), do: inspect(value)

  defp string_key(key) when is_atom(key), do: Atom.to_string(key)
  defp string_key(key) when is_binary(key), do: key
  defp string_key(key), do: inspect(key)

  defp metadata_key_name(key), do: string_key(key)

  defp reserved_payload_key?(key) do
    name = string_key(key)
    name in @reserved_payload_keys or google_metadata_key?(name)
  end

  defp google_metadata_key?(key) when is_binary(key),
    do: String.starts_with?(key, "logging.googleapis.com/")
end
