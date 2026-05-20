defmodule BullX.EventBus.RoutingTable do
  @moduledoc """
  In-memory active Event Routing Rule snapshot.

  The snapshot is reconstructible from code-owned built-in rules plus
  PostgreSQL-owned rules. Direct SQL edits are not a live-update path; callers
  use `refresh/1` after writer changes.
  """

  use GenServer

  import Ecto.Query

  alias BullX.EventBus.{EventRoutingRule, Matcher, SystemCommands}
  alias BullX.Repo

  defstruct rules: [], compiled?: false, last_error: nil

  @type t :: %__MODULE__{rules: [EventRoutingRule.t()], compiled?: boolean(), last_error: term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec refresh(GenServer.server()) :: :ok | {:error, term()}
  def refresh(server \\ __MODULE__) do
    call_or_direct(server, :refresh)
  end

  @spec snapshot(GenServer.server()) :: {:ok, [EventRoutingRule.t()]} | {:error, term()}
  def snapshot(server \\ __MODULE__) do
    call_or_direct(server, :snapshot)
  end

  @spec match(map(), GenServer.server()) ::
          {:ok, {:matched, EventRoutingRule.t(), list()}}
          | {:ok, {:no_match, list()}}
          | {:error, term()}
  def match(routing_context, server \\ __MODULE__) do
    with {:ok, rules} <- snapshot(server),
         {:ok, matcher_result} <- Matcher.match(rules, routing_context) do
      materialize_match(matcher_result, rules)
    end
  end

  @impl true
  def init(_opts) do
    case load_snapshot() do
      {:ok, rules} -> {:ok, %__MODULE__{rules: rules, compiled?: true}}
      {:error, reason} -> {:ok, %__MODULE__{rules: [], compiled?: false, last_error: reason}}
    end
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    case load_snapshot() do
      {:ok, rules} ->
        {:reply, :ok, %__MODULE__{rules: rules, compiled?: true}}

      {:error, reason} ->
        {:reply, {:error, reason}, failed_refresh_state(state, reason)}
    end
  end

  def handle_call(:snapshot, _from, %__MODULE__{compiled?: true, rules: rules} = state) do
    {:reply, {:ok, rules}, state}
  end

  def handle_call(:snapshot, _from, %__MODULE__{last_error: reason} = state) do
    {:reply, {:error, reason || :route_table_unavailable}, state}
  end

  # Direct branch is for boot-order callers (tests, migrations, init-time
  # refresh) where the GenServer may not be alive yet — they read straight
  # from the database instead.
  defp call_or_direct(server, message) do
    case GenServer.whereis(server) do
      nil -> direct(message)
      _pid -> GenServer.call(server, message)
    end
  end

  defp direct(:refresh), do: load_snapshot() |> normalize_refresh()
  defp direct(:snapshot), do: load_snapshot()

  defp normalize_refresh({:ok, _rules}), do: :ok
  defp normalize_refresh({:error, reason}), do: {:error, reason}

  defp failed_refresh_state(%__MODULE__{compiled?: true} = state, reason) do
    %{state | last_error: reason}
  end

  defp failed_refresh_state(%__MODULE__{} = state, reason) do
    %{state | rules: [], compiled?: false, last_error: reason}
  end

  defp load_snapshot do
    database_rules =
      EventRoutingRule
      |> where([r], r.active == true)
      |> order_by([r], asc: r.priority)
      |> Repo.all()

    rules =
      (SystemCommands.builtin_routing_rules() ++ database_rules)
      |> Enum.sort_by(& &1.priority)

    case Matcher.validate_route_table(rules) do
      :ok -> {:ok, rules}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Postgrex.Error -> {:error, Exception.message(error)}
    error in DBConnection.ConnectionError -> {:error, Exception.message(error)}
  end

  defp materialize_match({:no_match, diagnostics}, _rules), do: {:ok, {:no_match, diagnostics}}

  # The matcher (a Rust NIF) returns only the winning rule_id to keep the FFI
  # cheap. Re-find the full EventRoutingRule from the cached list so callers
  # get target_type, target_ref, scope settings, etc. without a round trip.
  # `:matched_rule_missing` here means a rule was retired between the cache
  # snapshot the matcher saw and the rules list we have — caller will fall
  # through to re-fetch.
  defp materialize_match({:matched, rule_id, diagnostics}, rules) do
    case Enum.find(rules, &(&1.id == rule_id)) do
      nil -> {:error, {:matched_rule_missing, rule_id}}
      rule -> {:ok, {:matched, rule, diagnostics}}
    end
  end
end
