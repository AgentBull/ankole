defmodule Ankole.SubagentDelegations.Control do
  @moduledoc false

  import Ecto.Query

  alias Ankole.Actors
  alias Ankole.Actors.ActorEvent
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.SubagentDelegations.Attrs
  alias Ankole.SubagentDelegations.Lifecycle
  alias Ankole.SubagentDelegations.Queries
  alias Ankole.SubagentDelegations.Schemas.Delegation

  @terminal_statuses Delegation.terminal_statuses()

  @spec request_stop(String.t(), map()) ::
          {:ok, %{delegation: Delegation.t(), command_event: ActorEvent.t() | nil}}
          | {:error, term()}
  def request_stop(delegation_id, attrs)
      when is_binary(delegation_id) and is_map(attrs) do
    attrs = Attrs.normalize(attrs)

    with {:ok, agent_uid} <- Principals.normalize_uid(Attrs.text(attrs, "agent_uid")) do
      now = now()

      Repo.transact(fn repo ->
        case Queries.get_for_agent(repo, delegation_id, agent_uid, lock: "FOR UPDATE") do
          %Delegation{status: status} = delegation when status in @terminal_statuses ->
            {:ok, %{delegation: delegation, command_event: nil}}

          %Delegation{status: status} = delegation when status in ["queued", "waiting_on_user"] ->
            with {:ok, delegation} <- stop_without_live_turn(repo, delegation, attrs, now),
                 :ok <- complete_pending_delegation_events(repo, delegation, now),
                 :ok <- Lifecycle.nudge_queued_after_slot_release(repo, delegation, now) do
              {:ok, %{delegation: delegation, command_event: nil}}
            end

          %Delegation{} = delegation ->
            with {:ok, delegation} <- stop_without_live_turn(repo, delegation, attrs, now),
                 :ok <- Lifecycle.nudge_queued_after_slot_release(repo, delegation, now),
                 {:ok, command_event} <- append_command(repo, delegation, "stop", attrs, now) do
              {:ok, %{delegation: delegation, command_event: command_event}}
            end

          nil ->
            {:error, :delegation_not_found}
        end
      end)
    end
  end

  @spec request_steer(String.t(), map()) ::
          {:ok, %{delegation: Delegation.t(), command_event: ActorEvent.t()}}
          | {:error, term()}
  def request_steer(delegation_id, attrs)
      when is_binary(delegation_id) and is_map(attrs) do
    attrs = Attrs.normalize(attrs)
    answers = Map.get(attrs, "answers")

    with {:ok, agent_uid} <- Principals.normalize_uid(Attrs.text(attrs, "agent_uid")),
         :ok <- require_steer_input(Attrs.text(attrs, "text"), answers) do
      Repo.transact(fn repo ->
        with %Delegation{} = delegation <-
               Queries.get_for_agent(repo, delegation_id, agent_uid, lock: "FOR UPDATE"),
             :ok <- reject_terminal_steer(delegation),
             {:ok, command_event} <- append_command(repo, delegation, "steer", attrs, now()) do
          {:ok, %{delegation: delegation, command_event: command_event}}
        else
          nil -> {:error, :delegation_not_found}
          {:error, _reason} = error -> error
        end
      end)
    end
  end

  defp stop_without_live_turn(repo, delegation, attrs, now) do
    metadata =
      delegation.metadata
      |> Kernel.||(%{})
      |> Map.merge(
        Attrs.reject_nil_values(%{
          "cancel_requested_by" => Attrs.text(attrs, "cancel_requested_by"),
          "cancel_reason" => Attrs.text(attrs, "reason")
        })
      )

    delegation
    |> Delegation.changeset(%{status: "stopped", completed_at: now, metadata: metadata})
    |> repo.update()
  end

  defp complete_pending_delegation_events(repo, delegation, now) do
    ActorEvent
    |> where([event], event.agent_uid == ^delegation.agent_uid)
    |> where([event], event.session_id == ^"subagent:#{delegation.id}")
    |> where([event], event.type in ["subagent.delegation.dispatch", "command.steer"])
    |> where([event], is_nil(event.completed_at))
    |> lock("FOR UPDATE")
    |> repo.all()
    |> Enum.reduce_while(:ok, fn event, :ok ->
      case Actors.mark_event_completed_in_tx(repo, event, now) do
        {:ok, %ActorEvent{}} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp require_steer_input(text, answers)
       when is_binary(text) or (is_map(answers) and map_size(answers) > 0),
       do: :ok

  defp require_steer_input(_text, _answers), do: {:error, :subagent_steer_input_missing}

  defp reject_terminal_steer(%Delegation{status: status}) when status in @terminal_statuses,
    do: {:error, :subagent_delegation_terminal}

  defp reject_terminal_steer(%Delegation{}), do: :ok

  defp append_command(repo, delegation, command, attrs, now) do
    reply_route = delegation.reply_route || %{}
    request_id = Attrs.text(attrs, "request_id") || Ecto.UUID.generate()
    args_text = Attrs.text(attrs, "text") || Attrs.text(attrs, "reason") || command

    command_data =
      Attrs.reject_nil_values(%{
        "argsText" => args_text,
        "answers" => map_or_nil(Map.get(attrs, "answers")),
        "cancel_requested_by" => Attrs.text(attrs, "cancel_requested_by")
      })

    Actors.append_actor_event_in_tx(repo, %{
      agent_uid: delegation.agent_uid,
      binding_name: Map.fetch!(reply_route, "binding_name"),
      session_id: "subagent:#{delegation.id}",
      source_event_id: "subagent_delegation:#{delegation.id}:#{command}:#{request_id}",
      signal_channel_id: Map.get(reply_route, "signal_channel_id"),
      provider_thread_id: Map.get(reply_route, "provider_thread_id"),
      source_entry_id: Map.get(reply_route, "source_entry_id"),
      type: "command.#{command}",
      available_at: now,
      payload: %{
        "type" => "command.#{command}",
        "data" => %{"command" => command_data}
      }
    })
  end

  defp map_or_nil(value) when is_map(value) and map_size(value) > 0, do: value
  defp map_or_nil(_value), do: nil
  defp now, do: DateTime.utc_now(:microsecond)
end
