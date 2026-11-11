defmodule Ankole.AIGateway.UsageConsole.Actions do
  @moduledoc """
  Reads the tenant usage summary for the Console: the tokens of
  language-model rounds, and what the calls of every other capability
  produced.

  The Agent breakdown keeps only rounds whose subject is an Agent, because a
  Human or system Principal can also call a model. Rows name their Principal.
  The ledger keeps the rounds of a deleted Agent, so its row stays in the Agent
  breakdown without a name when its Agent rounds show that it was an Agent.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(%{arguments: %{days: days}}, _opts, _context) do
    since = DateTime.add(DateTime.utc_now(:microsecond), -days * 86_400, :second)
    summary = Ankole.AIGateway.UsageLedger.window_summary(since)
    principals = principals(summary.by_agent ++ summary.by_human)

    agent? = fn row ->
      case principals[row.key] do
        %{type: type} -> type == :agent
        nil -> MapSet.member?(summary.agent_subjects, row.key)
      end
    end

    {:ok,
     %{
       window_started_at: DateTime.to_iso8601(since),
       total: summary.total,
       by_agent: for(row <- summary.by_agent, agent?.(row), do: named(row, principals)),
       by_human: Enum.map(summary.by_human, &named(&1, principals)),
       by_origin: summary.by_origin,
       by_capability: Ankole.AIGateway.UsageLedger.capability_summary(since)
     }}
  end

  defp principals(rows) do
    uids = rows |> Enum.map(& &1.key) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    [query: [filter: [uid: [in: uids]], select: [:uid, :type, :display_name]]]
    |> Ankole.Principals.list_principals!()
    |> Map.new(&{&1.uid, &1})
  end

  defp named(row, principals),
    do: Map.put(row, :name, get_in(principals, [row.key, Access.key(:display_name)]))
end
