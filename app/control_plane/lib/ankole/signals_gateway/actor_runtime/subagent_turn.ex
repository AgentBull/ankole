defmodule Ankole.SignalsGateway.ActorRuntime.SubagentTurn do
  @moduledoc false

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SubagentDelegations.Schemas.Delegation

  def opts(%ActorEvent{} = input, %Delegation{} = delegation, opts) do
    base_context = Keyword.get(opts, :request_context, %{})

    context = %{
      "turn_mode" => "subagent_delegation",
      "delegation_id" => delegation.id,
      "parent_session_id" => delegation.session_id,
      "attempts" => delegation.attempts,
      "actor_event_type" => input.type,
      "silent_success_allowed" => true
    }

    Keyword.merge(opts,
      kind: "subagent_delegation",
      conversation: :none,
      request_context: Map.merge(base_context, context)
    )
  end
end
