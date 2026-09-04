defmodule Ankole.SignalsGateway.ActorRuntime.TurnControl do
  @moduledoc """
  Tells a worker to stop spending tokens on a turn that the control plane has
  already fenced in PostgreSQL, or to drop a Skill it can no longer use.

  The durable decision (cancel, supersede, retry, disable) commits first. The
  `turn_control` message is best-effort and goes out after the commit: stale
  worker output is already rejected by the turn fence, so a lost control costs
  tokens and worker capacity, never correctness.

  `collect/4` runs inside the caller's transaction on the deliveries that the
  caller has already selected and locked. It never queries and never opens a
  transaction, because `/stop`, `/new`, and source-entry retraction nest it in
  larger transactions. `dispatch/1` runs after the commit: it builds the
  envelope, sends it on the delivery's route, and marks a route that cannot
  receive as unusable, so the next turn is placed on a live worker.

  One control per worker turn: the worker keys an active turn by
  `activation_uid` and `actor_event_id`
  (`app/agent_computer/src/worker/active_turns.ts`), so the deliveries of every
  steer revision of one turn collapse into one control that carries the newest
  fence.
  """

  import Ankole.SignalsGateway.ActorRuntime.Common, only: [reason_text: 1]

  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker
  alias Ankole.SignalsGateway.ActorRuntime.TurnEnvelope
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAdmission

  @verbs [:stop, :retry, :skill_disabled]

  @type verb :: :stop | :retry | :skill_disabled

  @type control :: %{
          route: String.t(),
          turn_ref: TurnRef.t(),
          verb: verb(),
          reason: String.t() | nil,
          payload: map()
        }

  @type outcome :: %{
          required(:route) => String.t(),
          required(:turn_ref) => TurnRef.t(),
          required(:verb) => verb(),
          required(:reason) => String.t() | nil,
          required(:payload) => map(),
          required(:send_outcome) => String.t(),
          optional(:send_error) => term()
        }

  @doc """
  Builds the control set for the given deliveries. The route is the delivery's
  transport route, or its worker id when the route was never recorded; a
  delivery with neither is dropped. `payload:` adds fields to the wire payload;
  `reason` is added as `"reason"` when it is not nil.
  """
  @spec collect([ActorEventDelivery.t()], verb(), term(), keyword()) :: [control()]
  def collect(deliveries, verb, reason, opts \\ [])
      when is_list(deliveries) and verb in @verbs and is_list(opts) do
    payload = Keyword.get(opts, :payload, %{})
    reason = if is_nil(reason), do: nil, else: reason_text(reason)

    deliveries
    |> Enum.sort_by(&{&1.revision, &1.attempt_no}, :desc)
    |> Enum.reject(&is_nil(route(&1)))
    |> Enum.uniq_by(&{route(&1), &1.activation_uid, &1.actor_event_id_fence})
    |> Enum.map(fn delivery ->
      %{
        route: route(delivery),
        turn_ref: TurnRef.from_delivery(delivery),
        verb: verb,
        reason: reason,
        payload: payload
      }
    end)
  end

  @doc """
  Sends every control on its route after the commit and returns one outcome
  per control.
  """
  @spec dispatch([control()]) :: [outcome()]
  def dispatch(controls) when is_list(controls), do: Enum.map(controls, &send_control/1)

  defp send_control(%{route: route, turn_ref: %TurnRef{} = turn_ref, verb: verb} = control) do
    envelope = TurnEnvelope.turn_control(turn_ref, Atom.to_string(verb), wire_payload(control))

    case Broker.send_mandatory(route, envelope) do
      {:ok, :sent_or_queued} ->
        Map.put(control, :send_outcome, "sent_or_queued")

      {:error, reason} ->
        WorkerAdmission.mark_route_unusable(route, reason)

        control
        |> Map.put(:send_outcome, reason_text(reason))
        |> Map.put(:send_error, reason)
    end
  end

  defp wire_payload(%{payload: payload, reason: nil}), do: payload
  defp wire_payload(%{payload: payload, reason: reason}), do: Map.put(payload, "reason", reason)

  defp route(%ActorEventDelivery{transport_route: route, worker_id: worker_id}),
    do: route || worker_id
end
