defmodule Ankole.ActorRuntime.CommitCoordinator.Deliveries do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.Actors.ActorInput
  alias Ankole.ActorRuntime.CommitCoordinator.Fences
  alias Ankole.ActorRuntime.CommitCoordinator.Payload
  alias Ankole.ActorRuntime.Schemas.ActorInputDelivery

  def accepted(repo, turn_ref) do
    llm_turn_id = Payload.fetch_turn_id(turn_ref)

    deliveries =
      ActorInputDelivery
      |> where([delivery], delivery.llm_turn_id == ^llm_turn_id)
      |> where([delivery], delivery.state == "accepted")
      |> lock("FOR UPDATE")
      |> repo.all()

    case deliveries do
      [] ->
        {:error, :no_accepted_delivery}

      deliveries ->
        deliveries
        |> Fences.validate_deliveries_turn_ref(turn_ref)
        |> case do
          :ok -> {:ok, deliveries}
          {:error, _reason} = error -> error
        end
    end
  end

  def lock_actor_inputs(repo, deliveries) do
    input_ids = Enum.map(deliveries, & &1.actor_input_id)

    actor_inputs =
      ActorInput
      |> where([input], input.id in ^input_ids)
      |> where([input], input.input_state == "open")
      |> order_by([input], asc: input.live_queue_sequence)
      |> lock("FOR UPDATE")
      |> repo.all()

    case MapSet.new(Enum.map(actor_inputs, & &1.id)) == MapSet.new(input_ids) do
      true -> {:ok, actor_inputs}
      false -> {:error, :actor_input_not_open}
    end
  end

  def delete(repo, actor_inputs) do
    input_ids = Enum.map(actor_inputs, & &1.id)

    ActorInputDelivery
    |> where([delivery], delivery.actor_input_id in ^input_ids)
    |> repo.delete_all()
  end

  def release_deferred_summary(_repo, []), do: {0, nil}

  def release_deferred_summary(repo, actor_inputs) do
    delete(repo, actor_inputs)
  end

  def supersede_turn(repo, turn_ref, now, reason) do
    turn_ref
    |> Payload.fetch_turn_id()
    |> supersede_turn_by_id(repo, now, reason)
  end

  defp supersede_turn_by_id(llm_turn_id, repo, now, reason) do
    ActorInputDelivery
    |> where([delivery], delivery.llm_turn_id == ^llm_turn_id)
    |> where([delivery], delivery.state in ^ActorInputDelivery.live_states())
    |> repo.update_all(
      set: [
        state: "superseded",
        superseded_at: now,
        error: %{"reason" => inspect(reason)},
        updated_at: now
      ]
    )
  end
end
