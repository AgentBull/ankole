defmodule BullX.Runtime.SignalRouting.Cache do
  @moduledoc false

  use GenServer

  import Ecto.Query

  require Logger

  alias BullX.Principals.{Agent, Principal}
  alias BullX.Repo
  alias BullX.Runtime.SignalRouting.{Matcher, Rule}

  @type state :: %{rules: [Rule.t()]}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @spec snapshot() :: {:ok, [Rule.t()]} | {:error, :not_running | :down}
  def snapshot do
    call(:snapshot)
  end

  @spec refresh_all() :: :ok | {:error, :not_running | :down | term()}
  def refresh_all do
    call(:refresh_all)
  end

  @impl true
  def init(:ok) do
    case load_rules() do
      {:ok, rules} ->
        {:ok, %{rules: rules}}

      {:error, :table_missing} ->
        Logger.warning("BullX.SignalRouting.Cache: route tables missing, starting empty")
        {:ok, %{rules: []}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, {:ok, state.rules}, state}
  end

  def handle_call(:refresh_all, _from, state) do
    case load_rules() do
      {:ok, rules} ->
        :telemetry.execute(
          [:bullx, :runtime, :signal_routing, :cache, :refreshed],
          %{rules: length(rules)},
          %{}
        )

        {:reply, :ok, %{state | rules: rules}}

      {:error, :table_missing} ->
        Logger.warning("BullX.SignalRouting.Cache: route tables missing during refresh")
        {:reply, :ok, %{state | rules: []}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp call(message) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_running}

      _pid ->
        safe_call(message)
    end
  end

  defp safe_call(message) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, _reason -> {:error, :down}
  end

  defp load_rules do
    query =
      from rule in Rule,
        left_join: agent in Agent,
        on: agent.principal_id == rule.agent_principal_id,
        left_join: principal in Principal,
        on: principal.id == agent.principal_id,
        where:
          rule.enabled == true and
            (rule.route_action == :drop_signal or
               (rule.route_action == :deliver_agent and principal.type == :agent and
                  principal.status == :active)),
        order_by: [desc: rule.priority, asc: rule.key]

    try do
      query
      |> Repo.all()
      |> Matcher.normalize_rules()
    rescue
      error in Postgrex.Error ->
        case table_missing?(error) do
          true -> {:error, :table_missing}
          false -> {:error, error}
        end

      error ->
        {:error, error}
    end
  end

  defp table_missing?(%Postgrex.Error{postgres: %{code: code}})
       when code in [:undefined_table, :undefined_object],
       do: true

  defp table_missing?(_error), do: false
end
