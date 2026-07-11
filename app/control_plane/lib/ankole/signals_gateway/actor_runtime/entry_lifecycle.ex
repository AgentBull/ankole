defmodule Ankole.SignalsGateway.ActorRuntime.EntryLifecycle do
  @moduledoc false

  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.Repo
  alias Ankole.Schedule

  def process(%ActorEvent{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %ActorEvent{} = input <- Actors.lock_actor_event_in_tx(repo, input.id),
           {:ok, cancelled_checkbacks} <-
             Schedule.cancel_checkbacks_for_provider_entry_in_tx(
               repo,
               %{
                 "agent_uid" => input.agent_uid,
                 "session_id" => input.session_id,
                 "binding_name" => input.binding_name,
                 "source_entry_id" => input.source_entry_id
               },
               now
             ) do
        ignore_lifecycle_event(repo, input, cancelled_checkbacks, now)
      else
        nil -> {:ok, %{status: :idle}}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp ignore_lifecycle_event(repo, %ActorEvent{} = input, cancelled_checkbacks, now) do
    with {:ok, aigateway_deletions} <- hard_delete_visible_aigateway_tail(repo, input, now),
         {:ok, completed_event} <- complete_lifecycle_event(repo, input, now) do
      {:ok,
       %{
         status: :entry_lifecycle_ignored,
         lifecycle_event: input,
         cancelled_checkbacks: cancelled_checkbacks,
         aigateway_deletions: aigateway_deletions,
         actor_event: completed_event
       }}
    end
  end

  defp hard_delete_visible_aigateway_tail(
         repo,
         %ActorEvent{source_entry_id: source_entry_id} = input,
         now
       )
       when is_binary(source_entry_id) and source_entry_id != "" do
    Actors.actor_events_for_entry_in_tx(
      repo,
      input.agent_uid,
      input.binding_name,
      input.signal_channel_id,
      source_entry_id
    )
    |> Enum.map(
      &AIGatewayLink.delete_visible_turn_suffix_in_tx(
        repo,
        &1.agent_uid,
        &1.session_id,
        &1.id,
        now
      )
    )
    |> collect_results()
  end

  defp hard_delete_visible_aigateway_tail(_repo, %ActorEvent{}, _now), do: {:ok, []}

  defp complete_lifecycle_event(repo, %ActorEvent{} = input, now) do
    Actors.complete_entry_lifecycle_event_in_tx(repo, input, completed_at: now)
  end

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end
end
