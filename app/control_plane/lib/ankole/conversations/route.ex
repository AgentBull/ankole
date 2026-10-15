defmodule Ankole.Conversations.Route do
  @moduledoc "Resolves the durable source and long-lived recipient of a turn."

  import Ecto.Query

  alias Ankole.AIGateway
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Repo
  alias Ankole.Signals.Signal
  alias Ankole.Workflow
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  @type source :: %{
          signal_id: Ecto.UUID.t(),
          binding_name: String.t(),
          conversation_id: String.t() | nil,
          provider_thread_id: String.t() | nil,
          provider_message_id: String.t() | nil
        }

  @doc """
  Resolves the durable reply route for one turn.
  """
  @spec source(%{signal_id: Ecto.UUID.t()}) ::
          {:ok, source()} | {:error, :reply_route_not_in_turn}
  def source(%{signal_id: signal_id}) when is_binary(signal_id) do
    case Repo.get(Signal, signal_id) do
      %Signal{} = event ->
        {:ok,
         %{
           signal_id: event.id,
           binding_name: event.reply_binding_name,
           conversation_id: event.conversation_id,
           provider_thread_id: event.provider_thread_id,
           provider_message_id: event.provider_message_id
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
            "conversation_id" => source.conversation_id,
            "provider_thread_id" => source.provider_thread_id,
            "provider_message_id" => source.provider_message_id
          }

      {:ok, %{source: source, owner_session_id: owner.session_id, reply_route: route}}
    end
  end

  defp resolve_owner(agent_uid, session_id, route, visited)
       when is_binary(session_id) and session_id != "" do
    if MapSet.member?(visited, session_id) do
      {:error, :long_lived_reply_owner_not_found}
    else
      resolve_session_owner(
        Ankole.Sessions.Key.parse(session_id),
        agent_uid,
        session_id,
        route,
        MapSet.put(visited, session_id)
      )
    end
  end

  defp resolve_owner(_agent_uid, _session_id, _route, _visited),
    do: {:error, :long_lived_reply_owner_not_found}

  defp resolve_session_owner({:job, _}, agent_uid, session_id, _route, visited) do
    with {:ok, job_id} <- BackgroundAgentJobs.parse_job_session_id(session_id),
         %Job{} = job <- Repo.get_by(Job, id: job_id, agent_uid: agent_uid),
         conversation_id when is_binary(conversation_id) <-
           Map.get(job.metadata || %{}, "owner_conversation_id"),
         {:ok, %{conversation_key: owner_session_id}} <-
           AIGateway.get_conversation(agent_uid, conversation_id, include_ended: true),
         true <- owner_session_id == job.owner_session_id,
         %{} = reply_route <- job.reply_route do
      resolve_owner(agent_uid, owner_session_id, reply_route, visited)
    else
      _missing -> {:error, :long_lived_reply_owner_not_found}
    end
  end

  defp resolve_session_owner({:workflow_task, _}, agent_uid, session_id, _route, visited) do
    with {:ok, call_id} <- Workflow.parse_task_session_id(session_id),
         %AgentCall{} = call <- Repo.get_by(AgentCall, id: call_id, agent_uid: agent_uid),
         %Run{} = run <- Repo.get_by(Run, id: call.run_id, agent_uid: agent_uid),
         %{} = reply_route <- run.reply_route do
      resolve_owner(agent_uid, run.owner_session_id, reply_route, visited)
    else
      _missing -> {:error, :long_lived_reply_owner_not_found}
    end
  end

  defp resolve_session_owner(_kind, agent_uid, session_id, route, _visited) do
    native_id = native_conversation_id(agent_uid, session_id)

    case route do
      nil when not is_nil(native_id) ->
        {:ok, %{session_id: session_id, reply_route: %{"conversation_id" => native_id}}}

      nil ->
        {:ok, %{session_id: session_id, reply_route: nil}}

      %{"conversation_id" => id} when id == native_id and not is_nil(id) ->
        {:ok, %{session_id: session_id, reply_route: route}}

      %{"binding_name" => binding_name} when is_binary(binding_name) and binding_name != "" ->
        if AIGateway.conversation_exists_by_key?(Repo, agent_uid, session_id) do
          {:ok, %{session_id: session_id, reply_route: route}}
        else
          {:error, :long_lived_reply_owner_not_found}
        end

      _invalid ->
        {:error, :long_lived_reply_owner_not_found}
    end
  end

  def snapshot(turn) do
    case Ankole.Repo.get(Signal, turn.signal_id) do
      %Signal{} = event ->
        route =
          %{
            "binding_name" => event.reply_binding_name,
            "conversation_id" => event.conversation_id,
            "provider_thread_id" => event.provider_thread_id,
            "provider_message_id" => event.provider_message_id
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        case Signal.scheduled_delivery_snapshot(event) do
          %{} = delivery -> Map.put(route, "delivery", delivery)
          _ -> route
        end

      _ ->
        %{}
    end
  end

  defp native_conversation_id(agent_uid, key) do
    with {:conversation, id} <- Ankole.Sessions.Key.parse(key),
         true <-
           Repo.exists?(
             from p in Ankole.Conversations.Participant,
               join: c in Ankole.Conversations.Conversation,
               on: c.id == p.conversation_id and c.tenant_id == p.tenant_id,
               where:
                 c.id == ^id and c.kind == :native and p.principal_uid == ^agent_uid and
                   p.role == :agent
           ) do
      id
    else
      _ -> nil
    end
  end
end
