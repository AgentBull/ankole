defmodule Ankole.SignalsGateway.ActorRuntime.TurnControl do
  @moduledoc """
  Sends a best-effort control for one durable Job attempt after its domain
  change commits. PostgreSQL rejects stale writes if the Worker misses it.
  """

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRoute
  alias Ankole.SignalsGateway.ActorRuntime.TurnEnvelope
  alias Ankole.Conversations.JobTurnRef
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAdmission

  @type verb :: :stop | :retry | :skill_disabled

  @type control :: %{
          turn_ref: JobTurnRef.t(),
          verb: verb(),
          reason: String.t() | nil,
          payload: map()
        }

  @doc "Sends each control after commit. PostgreSQL fences a missed or stale command."
  @spec dispatch([control()]) :: :ok
  def dispatch(controls) when is_list(controls), do: Enum.each(controls, &send_control/1)

  defp send_control(%{turn_ref: %JobTurnRef{} = turn_ref, verb: verb} = control) do
    case AgentWorkers.connected_worker(turn_ref.agent_uid) do
      {:ok, worker} ->
        target = AgentWorkers.target(worker)

        envelope =
          TurnEnvelope.turn_control(turn_ref, Atom.to_string(verb), wire_payload(control))

        case WorkerRoute.send_mandatory(target, envelope) do
          {:ok, :sent_or_queued} -> :ok
          {:error, reason} -> WorkerAdmission.mark_route_unusable(target.transport_route, reason)
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp wire_payload(%{payload: payload, reason: nil}), do: payload
  defp wire_payload(%{payload: payload, reason: reason}), do: Map.put(payload, "reason", reason)
end
