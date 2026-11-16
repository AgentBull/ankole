defmodule Ankole.Signals.Coalesce do
  @moduledoc """
  Fixed-window burst coalescing and open queue-tail batching for Agent Signal Bindings.

  A coalesced Binding opens an unstarted `queued` Signal with
  `available_at = first_received_at + window_ms`. Subsequent matching events
  append in arrival order while that batch remains unstarted (`last_attempt_at == nil`)
  and unsealed. Reaching `max_batch_size` or `@max_batch_bytes` seals the batch
  and pulls `available_at` up to `min(available_at, now)` without ever pushing
  a deadline into the future.
  """

  alias Ankole.Principals.WorkAccess
  alias Ankole.Signals.Signal

  @default_window_ms 5_000
  @max_window_ms 300_000
  @default_max_batch_size 20
  @max_batch_size_limit 100
  @max_batch_bytes 65_536
  @group_by_values ~w(binding subject)

  def max_batch_bytes, do: @max_batch_bytes

  def default_routine_config do
    %{
      "enabled" => true,
      "window_ms" => @default_window_ms,
      "max_batch_size" => @default_max_batch_size,
      "group_by" => "binding"
    }
  end

  @spec normalize_config(term()) :: {:ok, map() | nil} | {:error, String.t()}
  def normalize_config(nil), do: {:ok, nil}

  def normalize_config(config) when is_map(config) do
    normalized = Ankole.Attrs.normalize_external_attrs(config)
    unknown = Map.keys(normalized) -- ~w(enabled window_ms max_batch_size group_by)

    if unknown != [] do
      {:error, "unknown coalesce fields: #{Enum.join(Enum.sort(unknown), ", ")}"}
    else
      with {:ok, enabled} <- normalize_enabled(Map.get(normalized, "enabled", true)),
           {:ok, window_ms} <-
             normalize_int(
               Map.get(normalized, "window_ms", @default_window_ms),
               0,
               @max_window_ms,
               "window_ms"
             ),
           {:ok, max_batch_size} <-
             normalize_int(
               Map.get(normalized, "max_batch_size", @default_max_batch_size),
               1,
               @max_batch_size_limit,
               "max_batch_size"
             ),
           {:ok, group_by} <- normalize_group_by(Map.get(normalized, "group_by", "binding")) do
        {:ok,
         %{
           "enabled" => enabled,
           "window_ms" => window_ms,
           "max_batch_size" => max_batch_size,
           "group_by" => group_by
         }}
      end
    end
  end

  def normalize_config(_other), do: {:error, "coalesce must be an object or null"}

  @spec validate_config(term()) :: :ok | {:error, String.t()}
  def validate_config(nil), do: :ok

  def validate_config(config) do
    case normalize_config(config) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec enabled?(term()) :: boolean()
  def enabled?(%{"enabled" => false}), do: false

  def enabled?(%{} = config) when map_size(config) > 0 do
    window_ms = Map.get(config, "window_ms", @default_window_ms)
    max_batch_size = Map.get(config, "max_batch_size", @default_max_batch_size)
    not (window_ms == 0 and max_batch_size <= 1)
  end

  def enabled?(_), do: false

  @spec auth_fingerprint(map()) :: String.t()
  def auth_fingerprint(authorization) do
    fields = WorkAccess.fields(authorization)

    "#{fields.authorization_kind}:#{fields.human_uid || ""}:#{fields.human_access_version || ""}"
  end

  @spec group_key(map(), String.t() | nil) :: String.t()
  def group_key(%{"group_by" => "subject"}, subject), do: "subject:#{subject || ""}"
  def group_key(_config, _subject), do: "binding"

  @spec spec(struct(), struct() | nil, map(), map()) :: map() | nil
  def spec(binding, routine, authorization, signal) do
    if not String.starts_with?(binding.name || "", "source:") and enabled?(binding.coalesce) do
      {:ok, config} = normalize_config(binding.coalesce)

      %{
        binding_id: binding.id,
        group_key: group_key(config, signal["subject"]),
        definition_version: if(routine, do: routine.definition_version || 1, else: 1),
        auth_fingerprint: auth_fingerprint(authorization),
        window_ms: config["window_ms"],
        max_batch_size: config["max_batch_size"]
      }
    end
  end

  @spec envelope_from_fact(map()) :: map()
  def envelope_from_fact(fact) do
    base = %{
      "specversion" => "1.0",
      "id" => fact.source_event_id,
      "source" => fact.source,
      "type" => fact.type,
      "time" => DateTime.to_iso8601(fact.occurred_at),
      "data" => fact.data
    }

    base = if is_nil(fact.subject), do: base, else: Map.put(base, "subject", fact.subject)

    reserved =
      ~w(specversion id source type subject time data data_base64 ankole_routine ankole_coalesce)

    Map.merge(Map.drop(fact.extensions || %{}, reserved), base)
  end

  @spec initial_batch(map(), map(), DateTime.t()) :: {map(), DateTime.t()}
  def initial_batch(spec, envelope, received_at) do
    events = [envelope]
    encoded_bytes = byte_size(Ankole.JSON.encode!(events))
    full? = spec.max_batch_size <= 1 or encoded_bytes >= @max_batch_bytes

    available_at =
      if full? or spec.window_ms == 0,
        do: received_at,
        else: DateTime.add(received_at, spec.window_ms, :millisecond)

    meta = %{
      "binding_id" => spec.binding_id,
      "group_key" => spec.group_key,
      "definition_version" => spec.definition_version,
      "auth_fingerprint" => spec.auth_fingerprint,
      "window_ms" => spec.window_ms,
      "max_batch_size" => spec.max_batch_size,
      "sealed" => full?,
      "events" => events
    }

    {meta, available_at}
  end

  @spec same_slot?(Signal.t(), map()) :: boolean()
  def same_slot?(%Signal{extensions: %{"ankole_coalesce" => meta}}, spec) when is_map(meta) do
    meta["binding_id"] == spec.binding_id and meta["group_key"] == spec.group_key
  end

  def same_slot?(_signal, _spec), do: false

  @spec compatible_open_batch?(Signal.t(), map()) :: boolean()
  def compatible_open_batch?(
        %Signal{status: :queued, last_attempt_at: nil, extensions: %{"ankole_coalesce" => meta}},
        spec
      )
      when is_map(meta) do
    meta["sealed"] != true and
      meta["binding_id"] == spec.binding_id and
      meta["group_key"] == spec.group_key and
      meta["definition_version"] == spec.definition_version and
      meta["auth_fingerprint"] == spec.auth_fingerprint
  end

  def compatible_open_batch?(_signal, _spec), do: false

  @spec sealed?(Signal.t()) :: boolean()
  def sealed?(%Signal{extensions: %{"ankole_coalesce" => %{"sealed" => true}}}), do: true
  def sealed?(_signal), do: false

  @spec batch_size(Signal.t()) :: non_neg_integer()
  def batch_size(%Signal{extensions: %{"ankole_coalesce" => %{"events" => events}}})
      when is_list(events),
      do: length(events)

  def batch_size(_signal), do: 0

  @spec seal_extensions(Signal.t()) :: map()
  def seal_extensions(%Signal{extensions: extensions}) do
    base = extensions || %{}
    coalesce = Map.get(base, "ankole_coalesce", %{})
    Map.put(base, "ankole_coalesce", Map.put(coalesce, "sealed", true))
  end

  @spec try_append(Signal.t(), map(), map(), DateTime.t()) ::
          {:appended, map(), DateTime.t()} | {:overflow, map(), DateTime.t()}
  def try_append(%Signal{} = signal, envelope, spec, received_at) do
    extensions = signal.extensions || %{}
    coalesce = Map.get(extensions, "ankole_coalesce", %{})
    events = Map.get(coalesce, "events", [])
    candidate = events ++ [envelope]
    candidate_bytes = byte_size(Ankole.JSON.encode!(candidate))
    max_size = spec.max_batch_size

    if length(candidate) > max_size or candidate_bytes > @max_batch_bytes do
      sealed_ext = Map.put(extensions, "ankole_coalesce", Map.put(coalesce, "sealed", true))
      {:overflow, sealed_ext, earlier_instant(signal.available_at, received_at)}
    else
      full? = length(candidate) >= max_size or candidate_bytes >= @max_batch_bytes

      updated_coalesce =
        coalesce
        |> Map.put("events", candidate)
        |> Map.put("sealed", full?)

      updated_ext = Map.put(extensions, "ankole_coalesce", updated_coalesce)

      available_at =
        if full?,
          do: earlier_instant(signal.available_at, received_at),
          else: signal.available_at

      {:appended, updated_ext, available_at}
    end
  end

  defp earlier_instant(%DateTime{} = left, %DateTime{} = right) do
    if DateTime.compare(left, right) == :gt, do: right, else: left
  end

  defp normalize_enabled(value) when is_boolean(value), do: {:ok, value}
  defp normalize_enabled(_), do: {:error, "enabled must be a boolean"}

  defp normalize_int(value, min, max, _field)
       when is_integer(value) and value >= min and value <= max,
       do: {:ok, value}

  defp normalize_int(_value, min, max, field),
    do: {:error, "#{field} must be an integer between #{min} and #{max}"}

  defp normalize_group_by(value) when value in @group_by_values, do: {:ok, value}

  defp normalize_group_by(_),
    do: {:error, "group_by must be one of #{Enum.join(@group_by_values, ", ")}"}
end
