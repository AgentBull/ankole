defmodule Ankole.SignalsGateway.ActorRuntime.ReplyRoute do
  @moduledoc "Resolves the durable source and long-lived recipient of a turn."

  import Ecto.Query

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Workflow
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  @type source :: %{
          actor_event_id: Ecto.UUID.t(),
          binding_name: String.t(),
          signal_channel_id: String.t() | nil,
          provider_thread_id: String.t() | nil,
          source_entry_id: String.t() | nil
        }

  @doc """
  Resolves the durable reply route for one turn.
  """
  @spec source(%{actor_event_id: Ecto.UUID.t()}) ::
          {:ok, source()} | {:error, :reply_route_not_in_turn}
  def source(%{actor_event_id: actor_event_id}) when is_binary(actor_event_id) do
    case Repo.get(ActorEvent, actor_event_id) do
      %ActorEvent{} = event ->
        {:ok,
         %{
           actor_event_id: event.id,
           binding_name: event.binding_name,
           signal_channel_id: event.signal_channel_id,
           provider_thread_id: event.provider_thread_id,
           source_entry_id: event.source_entry_id
         }}

      nil ->
        {:error, :reply_route_not_in_turn}
    end
  end

  def source(_turn), do: {:error, :reply_route_not_in_turn}

  @doc """
  Resolves the session that can receive a webhook or automation result after
  the calling Job or Workflow task ends. The caller remains the source of
  authorization and provenance. A resolved reply route replaces only the
  delivery destination, not that source.
  """
  @spec long_lived_owner(String.t(), String.t()) ::
          {:ok, %{session_id: String.t(), reply_route: map() | nil}}
          | {:error, :long_lived_reply_owner_not_found}
  def long_lived_owner(agent_uid, session_id)
      when is_binary(agent_uid) and is_binary(session_id) and session_id != "" do
    resolve_owner(agent_uid, session_id, nil, MapSet.new())
  end

  def long_lived_owner(_agent_uid, _session_id),
    do: {:error, :long_lived_reply_owner_not_found}

  @doc "Returns the current source with its long-lived delivery destination."
  def long_lived_source(turn) do
    with {:ok, source} <- source(turn),
         {:ok, owner} <- long_lived_owner(turn.agent_uid, turn.session_id) do
      route =
        owner.reply_route ||
          %{
            "binding_name" => source.binding_name,
            "signal_channel_id" => source.signal_channel_id,
            "provider_thread_id" => source.provider_thread_id,
            "source_entry_id" => source.source_entry_id
          }

      {:ok, %{source: source, owner_session_id: owner.session_id, reply_route: route}}
    end
  end

  defp resolve_owner(agent_uid, session_id, route, visited)
       when is_binary(session_id) and session_id != "" do
    if MapSet.member?(visited, session_id) do
      {:error, :long_lived_reply_owner_not_found}
    else
      resolve_session_owner(agent_uid, session_id, route, MapSet.put(visited, session_id))
    end
  end

  defp resolve_owner(_agent_uid, _session_id, _route, _visited),
    do: {:error, :long_lived_reply_owner_not_found}

  defp resolve_session_owner(agent_uid, "job:" <> _ = session_id, _route, visited) do
    with {:ok, job_id} <- BackgroundAgentJobs.parse_job_session_id(session_id),
         %Job{} = job <- Repo.get_by(Job, id: job_id, agent_uid: agent_uid),
         conversation_id when is_binary(conversation_id) <-
           Map.get(job.metadata || %{}, "owner_conversation_id"),
         %Conversation{conversation_key: owner_session_id} <-
           Repo.get_by(Conversation, id: conversation_id, subject_uid: agent_uid),
         true <- owner_session_id == job.owner_session_id,
         %{} = reply_route <- job.reply_route do
      resolve_owner(agent_uid, owner_session_id, reply_route, visited)
    else
      _missing -> {:error, :long_lived_reply_owner_not_found}
    end
  end

  defp resolve_session_owner(agent_uid, "wf_task:" <> _ = session_id, _route, visited) do
    with {:ok, call_id} <- Workflow.parse_task_session_id(session_id),
         %AgentCall{} = call <- Repo.get_by(AgentCall, id: call_id, agent_uid: agent_uid),
         %Run{} = run <- Repo.get_by(Run, id: call.run_id, agent_uid: agent_uid),
         %{} = reply_route <- run.reply_route do
      resolve_owner(agent_uid, run.owner_session_id, reply_route, visited)
    else
      _missing -> {:error, :long_lived_reply_owner_not_found}
    end
  end

  defp resolve_session_owner(agent_uid, session_id, route, _visited) do
    case route do
      nil ->
        {:ok, %{session_id: session_id, reply_route: nil}}

      %{"binding_name" => binding_name} when is_binary(binding_name) and binding_name != "" ->
        if Repo.exists?(
             from(conversation in Conversation,
               where:
                 conversation.subject_uid == ^agent_uid and
                   conversation.conversation_key == ^session_id
             )
           ) do
          {:ok, %{session_id: session_id, reply_route: route}}
        else
          {:error, :long_lived_reply_owner_not_found}
        end

      _invalid ->
        {:error, :long_lived_reply_owner_not_found}
    end
  end

  def snapshot(turn) do
    case Ankole.Repo.get(ActorEvent, turn.actor_event_id) do
      %ActorEvent{} = event ->
        route =
          %{
            "binding_name" => event.binding_name,
            "signal_channel_id" => event.signal_channel_id,
            "provider_thread_id" => event.provider_thread_id,
            "source_entry_id" => event.source_entry_id
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        case ActorEvent.scheduled_delivery_snapshot(event) do
          %{} = delivery -> Map.put(route, "delivery", delivery)
          _ -> route
        end

      _ ->
        %{}
    end
  end
end
