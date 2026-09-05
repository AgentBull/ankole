defmodule Ankole.AIGateway.CredentialPool do
  @moduledoc """
  Process-local selection, affinity, and health for provider credential pools.

  PostgreSQL owns credential entries. This process owns only derived runtime
  state. Each stored entry has a health revision, so a result from an old
  credential cannot change the health or affinity of its replacement. A
  restart can cause one extra upstream probe but cannot lose an operator
  credential.
  """

  use GenServer

  @strategies ~w(fill_first round_robin least_used random)
  @affinity_limit 10_000
  @unauthorized_cooldown_ms 5 * 60 * 1_000
  @default_cooldown_ms 60 * 60 * 1_000

  @type entry :: map()
  @type selection :: %{
          required(:entry) => entry(),
          required(:credential_id) => String.t(),
          required(:available_count) => pos_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, %{}, Keyword.put(opts, :name, __MODULE__))

  @doc """
  Selects one usable entry. Affinity is checked before the configured strategy.
  Each provider keeps its 10,000 most recently used affinity keys.
  """
  @spec select(String.t(), [entry()], String.t(), keyword()) ::
          {:ok, selection()} | {:error, {:credential_pool_exhausted, map()}}
  def select(provider_row_id, entries, strategy, opts \\ [])

  def select(provider_row_id, entries, strategy, opts)
      when is_binary(provider_row_id) and is_list(entries) and strategy in @strategies do
    GenServer.call(
      __MODULE__,
      {:select, provider_row_id, entries, strategy, Keyword.get(opts, :affinity_key),
       Keyword.get(opts, :exclude, [])}
    )
  end

  def select(provider_row_id, entries, _strategy, opts)
      when is_binary(provider_row_id) and is_list(entries) do
    select(provider_row_id, entries, "fill_first", opts)
  end

  @doc """
  Marks one attributed credential revision unavailable until the upstream
  reset or the status-specific fallback deadline.
  """
  @spec mark_exhausted(
          String.t(),
          entry(),
          integer() | nil,
          map() | list(),
          map() | term()
        ) :: :ok
  def mark_exhausted(
        provider_row_id,
        %{"id" => credential_id} = credential,
        provider_status,
        headers \\ %{},
        error \\ %{}
      )
      when is_binary(provider_row_id) and is_binary(credential_id) do
    GenServer.call(
      __MODULE__,
      {:mark_exhausted, provider_row_id, credential_key(credential), provider_status, headers,
       error}
    )
  end

  @doc """
  Marks one credential revision terminally unusable.
  """
  @spec mark_dead(String.t(), entry(), map() | term()) :: :ok
  def mark_dead(provider_row_id, %{"id" => credential_id} = credential, error \\ %{})
      when is_binary(provider_row_id) and is_binary(credential_id) do
    GenServer.call(
      __MODULE__,
      {:mark_dead, provider_row_id, credential_key(credential), error}
    )
  end

  @doc """
  Records a successful provider response without clearing a concurrent cooldown.
  """
  @spec observe_success(String.t(), entry(), map() | list()) :: :ok
  def observe_success(provider_row_id, %{"id" => credential_id} = credential, headers \\ [])
      when is_binary(provider_row_id) and is_binary(credential_id) do
    GenServer.call(
      __MODULE__,
      {:observe_success, provider_row_id, credential_key(credential), headers}
    )
  end

  @doc """
  Adds one terminal provider usage snapshot to the selected credential.

  Model usage and native image-tool usage stay in separate buckets because
  upstreams account for them as separate models.
  """
  @spec record_usage(String.t(), String.t(), map(), map()) :: :ok
  def record_usage(provider_row_id, credential_id, usage, tool_usage \\ %{})
      when is_binary(provider_row_id) and is_binary(credential_id) and is_map(usage) and
             is_map(tool_usage) do
    GenServer.call(
      __MODULE__,
      {:record_usage, provider_row_id, credential_id, usage, tool_usage}
    )
  end

  @doc """
  Returns the current safe runtime status for Console projection.
  """
  @spec statuses(String.t(), [entry()]) :: %{String.t() => map()}
  def statuses(provider_row_id, entries)
      when is_binary(provider_row_id) and is_list(entries) do
    GenServer.call(__MODULE__, {:statuses, provider_row_id, entries})
  end

  @doc false
  def reset_for_test, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call(
        {:select, provider_row_id, entries, strategy, affinity_key, excluded_ids},
        _from,
        state
      ) do
    now_ms = System.system_time(:millisecond)
    provider_state = state |> Map.get(provider_row_id, new_provider_state()) |> expire(now_ms)
    excluded_ids = MapSet.new(excluded_ids)

    available =
      entries
      |> Enum.with_index()
      |> Enum.filter(fn {entry, _index} ->
        usable_entry?(entry, provider_state.health, excluded_ids, now_ms)
      end)
      |> Enum.sort_by(fn {entry, index} -> {priority(entry), index} end)

    case choose(available, provider_state, strategy, affinity_key) do
      {:ok, entry, provider_state} ->
        credential_id = Map.fetch!(entry, "id")

        provider_state =
          provider_state
          |> remember_affinity(affinity_key, credential_key(entry))
          |> put_in([:last_selected_at, credential_id], now_ms)

        state = Map.put(state, provider_row_id, provider_state)

        {:reply,
         {:ok,
          %{
            entry: entry,
            credential_id: credential_id,
            available_count: length(available)
          }}, state}

      :error ->
        details = exhausted_details(provider_row_id, entries, provider_state, now_ms)
        {:reply, {:error, {:credential_pool_exhausted, details}}, state}
    end
  end

  def handle_call(
        {:mark_exhausted, provider_row_id, credential_key, provider_status, headers, error},
        _from,
        state
      ) do
    now_ms = System.system_time(:millisecond)
    provider_state = Map.get(state, provider_row_id, new_provider_state())
    until_ms = reset_at_ms(headers) || now_ms + fallback_cooldown_ms(provider_status)

    provider_state =
      provider_state
      |> put_in(
        [:health, credential_key],
        %{
          status: :exhausted,
          retry_at_ms: until_ms,
          error: error_projection(error, provider_status)
        }
      )
      |> put_rate_limits(credential_key, headers)
      |> drop_affinity_for(credential_key)

    {:reply, :ok, Map.put(state, provider_row_id, provider_state)}
  end

  def handle_call(
        {:mark_dead, provider_row_id, credential_key, error},
        _from,
        state
      ) do
    provider_state =
      state
      |> Map.get(provider_row_id, new_provider_state())
      |> put_in(
        [:health, credential_key],
        %{status: :dead, error: error_projection(error, 401)}
      )
      |> drop_affinity_for(credential_key)

    {:reply, :ok, Map.put(state, provider_row_id, provider_state)}
  end

  def handle_call({:observe_success, provider_row_id, credential_key, headers}, _from, state) do
    provider_state =
      state
      |> Map.get(provider_row_id, new_provider_state())
      |> put_rate_limits(credential_key, headers)

    {:reply, :ok, Map.put(state, provider_row_id, provider_state)}
  end

  def handle_call(
        {:record_usage, provider_row_id, credential_id, usage, tool_usage},
        _from,
        state
      ) do
    snapshot =
      %{}
      |> put_numeric_usage("model", usage)
      |> put_numeric_usage("image_gen", Map.get(tool_usage, "image_gen", %{}))

    provider_state =
      state
      |> Map.get(provider_row_id, new_provider_state())
      |> update_usage(credential_id, snapshot)

    {:reply, :ok, Map.put(state, provider_row_id, provider_state)}
  end

  def handle_call({:statuses, provider_row_id, entries}, _from, state) do
    now_ms = System.system_time(:millisecond)
    provider_state = state |> Map.get(provider_row_id, new_provider_state()) |> expire(now_ms)

    statuses =
      Map.new(entries, fn entry ->
        credential_id = Map.get(entry, "id")

        {credential_id, entry_status(entry, provider_state, now_ms)}
      end)

    {:reply, statuses, Map.put(state, provider_row_id, provider_state)}
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{}}

  defp choose([], _provider_state, _strategy, _affinity_key), do: :error

  defp choose(available, provider_state, strategy, affinity_key) do
    case affinity_entry(available, provider_state, affinity_key) do
      %{} = entry ->
        {:ok, entry, increment_count(provider_state, Map.fetch!(entry, "id"))}

      nil ->
        choose_by_strategy(available, provider_state, strategy)
    end
  end

  defp choose_by_strategy(available, provider_state, "round_robin") do
    {entry, source_index} =
      case provider_state.round_robin_after do
        nil ->
          hd(available)

        cursor ->
          Enum.find(available, hd(available), fn {entry, source_index} ->
            {priority(entry), source_index} > cursor
          end)
      end

    {:ok, entry,
     provider_state
     |> Map.put(:round_robin_after, {priority(entry), source_index})
     |> increment_count(Map.fetch!(entry, "id"))}
  end

  defp choose_by_strategy(available, provider_state, "least_used") do
    {entry, _source_index} =
      Enum.min_by(available, fn {entry, source_index} ->
        {Map.get(provider_state.counts, Map.fetch!(entry, "id"), 0), priority(entry),
         source_index}
      end)

    {:ok, entry, increment_count(provider_state, Map.fetch!(entry, "id"))}
  end

  defp choose_by_strategy(available, provider_state, "random") do
    {entry, _source_index} = Enum.random(available)
    {:ok, entry, increment_count(provider_state, Map.fetch!(entry, "id"))}
  end

  defp choose_by_strategy([{entry, _source_index} | _rest], provider_state, _fill_first) do
    {:ok, entry, increment_count(provider_state, Map.fetch!(entry, "id"))}
  end

  defp affinity_entry(_available, _provider_state, affinity_key)
       when not is_binary(affinity_key) or affinity_key == "",
       do: nil

  defp affinity_entry(available, provider_state, affinity_key) do
    case Map.get(provider_state.affinity, affinity_key) do
      nil ->
        nil

      {expected_key, _recency} ->
        Enum.find_value(available, fn {entry, _index} ->
          if credential_key(entry) == expected_key, do: entry
        end)
    end
  end

  defp usable_entry?(entry, health, excluded_ids, now_ms) do
    credential_id = Map.get(entry, "id")
    credential_key = credential_key(entry)

    is_binary(credential_id) and credential_id != "" and
      is_nil(Map.get(entry, "disabled_at")) and
      Map.get(entry, "reauth_required") != true and
      not MapSet.member?(excluded_ids, credential_id) and
      case Map.get(health, credential_key) do
        %{status: :dead} -> false
        %{status: :exhausted, retry_at_ms: until_ms} when until_ms > now_ms -> false
        _state -> true
      end
  end

  defp priority(entry) do
    case Map.get(entry, "priority") do
      value when is_integer(value) -> value
      _value -> 0
    end
  end

  defp remember_affinity(provider_state, affinity_key, credential_key)
       when is_binary(affinity_key) and affinity_key != "" do
    provider_state = drop_affinity(provider_state, affinity_key)
    recency = System.unique_integer([:monotonic])

    provider_state = %{
      provider_state
      | affinity: Map.put(provider_state.affinity, affinity_key, {credential_key, recency}),
        affinity_lru: :gb_trees.insert(recency, affinity_key, provider_state.affinity_lru)
    }

    if map_size(provider_state.affinity) > @affinity_limit do
      {_recency, oldest_key} = :gb_trees.smallest(provider_state.affinity_lru)
      drop_affinity(provider_state, oldest_key)
    else
      provider_state
    end
  end

  defp remember_affinity(provider_state, _affinity_key, _credential_key), do: provider_state

  defp increment_count(provider_state, credential_id) do
    update_in(provider_state, [:counts, credential_id], fn count -> (count || 0) + 1 end)
  end

  defp drop_affinity_for(provider_state, credential_key) do
    Enum.reduce(provider_state.affinity, provider_state, fn
      {key, {^credential_key, _recency}}, state -> drop_affinity(state, key)
      _entry, state -> state
    end)
  end

  defp drop_affinity(provider_state, affinity_key) do
    case Map.pop(provider_state.affinity, affinity_key) do
      {nil, _affinity} ->
        provider_state

      {{_credential_key, recency}, affinity} ->
        %{
          provider_state
          | affinity: affinity,
            affinity_lru: :gb_trees.delete(recency, provider_state.affinity_lru)
        }
    end
  end

  defp expire(provider_state, now_ms) do
    health =
      Map.reject(provider_state.health, fn
        {_credential_key, %{status: :exhausted, retry_at_ms: until_ms}} ->
          until_ms <= now_ms

        _entry ->
          false
      end)

    %{provider_state | health: health}
  end

  defp exhausted_details(provider_row_id, entries, provider_state, now_ms) do
    statuses =
      Map.new(entries, fn entry ->
        credential_id = Map.get(entry, "id")

        {credential_id, entry_status(entry, provider_state, now_ms)}
      end)

    retry_at =
      entries
      |> Enum.flat_map(fn entry ->
        case Map.get(provider_state.health, credential_key(entry)) do
          %{status: :exhausted, retry_at_ms: until_ms} when until_ms > now_ms -> [until_ms]
          _state -> []
        end
      end)
      |> Enum.min(fn -> nil end)
      |> case do
        nil -> nil
        milliseconds -> DateTime.from_unix!(milliseconds, :millisecond) |> DateTime.to_iso8601()
      end

    %{
      "provider_row_id" => provider_row_id,
      "retry_at" => retry_at,
      "statuses" => statuses
    }
  end

  defp entry_status(
         %{"id" => credential_id, "reauth_required" => true} = entry,
         provider_state,
         _now_ms
       ) do
    status_metadata(provider_state, credential_id, credential_key(entry))
    |> Map.merge(%{"status" => "dead", "reauth_required" => true})
  end

  defp entry_status(
         %{"id" => credential_id, "disabled_at" => disabled_at} = entry,
         provider_state,
         _now_ms
       )
       when is_binary(disabled_at) and disabled_at != "",
       do:
         status_metadata(provider_state, credential_id, credential_key(entry))
         |> Map.put("status", "disabled")

  defp entry_status(
         %{"id" => credential_id} = entry,
         %{health: health} = provider_state,
         now_ms
       ) do
    credential_key = credential_key(entry)

    case Map.get(health, credential_key) do
      %{status: :dead, error: error} ->
        provider_state
        |> status_metadata(credential_id, credential_key)
        |> Map.merge(error)
        |> Map.merge(%{"status" => "dead", "reauth_required" => true})

      %{status: :exhausted, retry_at_ms: until_ms, error: error} when until_ms > now_ms ->
        provider_state
        |> status_metadata(credential_id, credential_key)
        |> Map.merge(error)
        |> Map.merge(%{
          "status" => "exhausted",
          "retry_at" => DateTime.from_unix!(until_ms, :millisecond) |> DateTime.to_iso8601()
        })

      _health ->
        provider_state
        |> status_metadata(credential_id, credential_key)
        |> Map.put("status", "ok")
    end
  end

  defp status_metadata(provider_state, credential_id, credential_key) do
    %{
      "request_count" => Map.get(provider_state.counts, credential_id, 0),
      "rate_limits" => Map.get(provider_state.rate_limits, credential_key, %{}),
      "usage" => Map.get(provider_state.usage, credential_id, %{}),
      "last_selected_at" =>
        case Map.get(provider_state.last_selected_at, credential_id) do
          milliseconds when is_integer(milliseconds) ->
            DateTime.from_unix!(milliseconds, :millisecond) |> DateTime.to_iso8601()

          _missing ->
            nil
        end
    }
  end

  defp error_projection(error, provider_status) do
    error = if is_map(error), do: error, else: %{"reason" => inspect(error)}

    %{
      "last_error_code" =>
        text(Map.get(error, "code") || Map.get(error, :code)) ||
          if(is_integer(provider_status), do: Integer.to_string(provider_status)),
      "last_error_reason" => text(Map.get(error, "reason") || Map.get(error, :reason)),
      "last_error_message" => text(Map.get(error, "message") || Map.get(error, :message)),
      "provider_status" => provider_status
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp reset_at_ms(headers) do
    headers
    |> normalize_headers()
    |> Enum.find_value(fn {name, value} ->
      if is_binary(name) and String.downcase(name) == "x-codex-primary-reset-at",
        do: parse_reset_at(value)
    end)
  end

  defp normalize_headers(headers) when is_map(headers), do: Map.to_list(headers)

  defp normalize_headers(headers) when is_list(headers) do
    Enum.flat_map(headers, fn
      {name, value} -> [{name, value}]
      [name, value] -> [{name, value}]
      _entry -> []
    end)
  end

  defp normalize_headers(_headers), do: []

  defp put_rate_limits(provider_state, credential_key, headers) do
    rate_limits =
      headers
      |> normalize_headers()
      |> Enum.reduce(%{}, fn {name, value}, acc ->
        normalized_name = if is_binary(name), do: String.downcase(name)

        if is_binary(normalized_name) and String.starts_with?(normalized_name, "x-codex-") do
          case header_text(value) do
            nil -> acc
            text -> Map.put(acc, normalized_name, text)
          end
        else
          acc
        end
      end)

    if map_size(rate_limits) == 0 do
      provider_state
    else
      put_in(provider_state, [:rate_limits, credential_key], rate_limits)
    end
  end

  defp header_text(value) when is_binary(value), do: value
  defp header_text(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp header_text([value | _rest]), do: header_text(value)
  defp header_text(_value), do: nil

  defp put_numeric_usage(snapshot, _bucket, usage) when not is_map(usage), do: snapshot

  defp put_numeric_usage(snapshot, bucket, usage) do
    case numeric_usage(usage) do
      usage when map_size(usage) > 0 -> Map.put(snapshot, bucket, usage)
      _empty -> snapshot
    end
  end

  defp numeric_usage(usage) do
    Enum.reduce(usage, %{}, fn
      {key, value}, acc when is_number(value) and value >= 0 ->
        Map.put(acc, to_string(key), value)

      {key, %{} = value}, acc ->
        case numeric_usage(value) do
          nested when map_size(nested) > 0 -> Map.put(acc, to_string(key), nested)
          _empty -> acc
        end

      _entry, acc ->
        acc
    end)
  end

  defp update_usage(provider_state, _credential_id, snapshot) when map_size(snapshot) == 0,
    do: provider_state

  defp update_usage(provider_state, credential_id, snapshot) do
    update_in(provider_state, [:usage], fn usage ->
      Map.update(usage, credential_id, snapshot, &merge_usage(&1, snapshot))
    end)
  end

  defp merge_usage(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      cond do
        is_number(left_value) and is_number(right_value) -> left_value + right_value
        is_map(left_value) and is_map(right_value) -> merge_usage(left_value, right_value)
        true -> right_value
      end
    end)
  end

  defp parse_reset_at(value) when is_integer(value) and value > 10_000_000_000, do: value
  defp parse_reset_at(value) when is_integer(value) and value > 0, do: value * 1_000
  defp parse_reset_at([value | _rest]), do: parse_reset_at(value)

  defp parse_reset_at(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} ->
        parse_reset_at(integer)

      _value ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
          _error -> nil
        end
    end
  end

  defp parse_reset_at(_value), do: nil

  defp fallback_cooldown_ms(401), do: @unauthorized_cooldown_ms
  defp fallback_cooldown_ms(_provider_status), do: @default_cooldown_ms

  defp credential_key(%{"id" => credential_id, "health_revision" => revision})
       when is_binary(revision) and revision != "" do
    {credential_id, revision}
  end

  defp new_provider_state do
    %{
      health: %{},
      affinity: %{},
      affinity_lru: :gb_trees.empty(),
      counts: %{},
      last_selected_at: %{},
      rate_limits: %{},
      usage: %{},
      round_robin_after: nil
    }
  end

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(_value), do: nil
end
