defmodule BullX.Runtime.SignalRouting do
  @moduledoc """
  Runtime-owned Signal routing facade.

  This context owns route rule writes, cache refresh, routing helpers, and
  route-decision reads. Gateway remains transport-only and talks to the Runtime
  through the configured Router and ConsumerDelivery behaviours.
  """

  import Ecto.Query

  alias BullX.Principals.{Agent, Principal}
  alias BullX.Repo
  alias BullX.Runtime.SignalRouting.{Cache, RouteDecision, Rule, Writer}

  defdelegate create_rule(attrs), to: Writer
  defdelegate update_rule(rule_or_id, attrs), to: Writer
  defdelegate delete_rule(rule_or_id), to: Writer
  defdelegate refresh_cache(), to: Cache, as: :refresh_all

  @spec get_rule(Ecto.UUID.t() | String.t()) :: Rule.t() | nil
  def get_rule(id_or_key), do: Writer.get_rule(id_or_key)

  @spec list_rules() :: [Rule.t()]
  def list_rules do
    Repo.all(from rule in Rule, order_by: [desc: rule.priority, asc: rule.key])
  end

  @spec get_route_decision(Ecto.UUID.t()) :: RouteDecision.t() | nil
  def get_route_decision(id) when is_binary(id), do: Repo.get(RouteDecision, id)

  @spec agent_destination_active?(Ecto.UUID.t() | nil) :: boolean()
  def agent_destination_active?(agent_principal_id) when is_binary(agent_principal_id) do
    Repo.exists?(
      from agent in Agent,
        join: principal in Principal,
        on: principal.id == agent.principal_id,
        where:
          agent.principal_id == ^agent_principal_id and principal.type == :agent and
            principal.status == :active,
        select: 1
    )
  end

  def agent_destination_active?(_agent_principal_id), do: false
end
