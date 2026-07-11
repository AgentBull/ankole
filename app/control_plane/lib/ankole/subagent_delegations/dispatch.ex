defmodule Ankole.SubagentDelegations.Dispatch do
  @moduledoc false

  import Ecto.Query

  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.RuntimeEvents
  alias Ankole.SubagentDelegations.Attrs
  alias Ankole.SubagentDelegations.Schemas.Delegation

  @spec create_with_dispatch(map()) ::
          {:ok, %{delegation: Delegation.t(), dispatch_event: ActorEvent.t()}} | {:error, term()}
  def create_with_dispatch(attrs) when is_map(attrs) do
    now = now()

    with attrs when is_map(attrs) <- Attrs.normalize(attrs),
         {:ok, agent_uid} <- Principals.normalize_uid(Attrs.text(attrs, "agent_uid")),
         {:ok, reply_route} <- reply_route(attrs),
         {:ok, codex_account_id} <- codex_account_id(agent_uid) do
      attrs =
        attrs
        |> Map.put("agent_uid", agent_uid)
        |> Map.put("reply_route", reply_route)
        |> Map.put("codex_account_id", codex_account_id)
        |> Map.put_new("runtime", "codex")
        |> Map.put_new("status", "queued")
        |> Map.put_new("attempts", 0)
        |> Map.put_new("queued_at", now)
        |> Map.put_new("result", %{})
        |> Map.put_new("error", %{})
        |> Map.put_new("metadata", %{})

      Repo.transact(fn repo ->
        with {:ok, delegation} <- insert_or_get_delegation(repo, attrs),
             {:ok, dispatch_event} <- append_dispatch_event(repo, delegation, now) do
          {:ok, %{delegation: delegation, dispatch_event: dispatch_event}}
        end
      end)
    end
  end

  defp codex_account_id(agent_uid) do
    case ModelProfiles.get_model_profile(agent_uid, "coding") do
      {:ok, %{"codex_account_id" => account_id}} -> {:ok, account_id}
      {:ok, %{"provider_id" => _provider_id}} -> {:ok, "aigateway"}
      {:error, :model_profile_not_configured} -> {:ok, "aigateway"}
      {:error, _reason} = error -> error
    end
  end

  @spec defer_actor_event(ActorEvent.t(), DateTime.t()) ::
          {:ok, ActorEvent.t()} | {:error, term()}
  def defer_actor_event(%ActorEvent{} = actor_event, %DateTime{} = available_at) do
    Repo.transact(fn repo ->
      with %ActorEvent{} = actor_event <- lock_open_actor_event(repo, actor_event.id),
           {:ok, actor_event} <-
             actor_event
             |> ActorEvent.changeset(%{available_at: available_at})
             |> repo.update(),
           :ok <-
             RuntimeEvents.notify_actor_session_ready(
               repo,
               actor_event.agent_uid,
               actor_event.session_id,
               available_at
             ) do
        {:ok, actor_event}
      else
        nil -> {:ok, actor_event}
        {:error, _reason} = error -> error
      end
    end)
  end

  @spec complete_actor_event(ActorEvent.t()) :: {:ok, ActorEvent.t()} | {:error, term()}
  def complete_actor_event(%ActorEvent{} = actor_event) do
    Repo.transact(fn repo ->
      case lock_open_actor_event(repo, actor_event.id) do
        %ActorEvent{} = event ->
          SignalsGateway.mark_actor_event_completed_in_tx(repo, event, now())

        nil ->
          {:ok, actor_event}
      end
    end)
  end

  @spec complete_open_dispatch(String.t(), String.t()) :: :ok | {:error, term()}
  def complete_open_dispatch(delegation_id, agent_uid) do
    Repo.transact(fn repo ->
      complete_open_events_in_tx(
        repo,
        delegation_id,
        agent_uid,
        ["subagent.delegation.dispatch"],
        now()
      )
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def complete_all_open_events_in_tx(repo, delegation_id, agent_uid, %DateTime{} = completed_at) do
    complete_open_events_in_tx(
      repo,
      delegation_id,
      agent_uid,
      ["subagent.delegation.dispatch", "command.steer"],
      completed_at
    )
  end

  @doc false
  def pending_steer_events(delegation_id, agent_uid, excluded_event_id) do
    Repo.transact(fn repo ->
      {:ok, pending_steer_events_in_tx(repo, delegation_id, agent_uid, excluded_event_id)}
    end)
  end

  defp pending_steer_events_in_tx(repo, delegation_id, agent_uid, excluded_event_id) do
    ActorEvent
    |> where([event], event.agent_uid == ^agent_uid)
    |> where([event], event.session_id == ^"subagent:#{delegation_id}")
    |> where([event], event.type == "command.steer")
    |> where([event], event.input_state == "open")
    |> where([event], is_nil(event.completed_at))
    |> where([event], event.id != ^excluded_event_id)
    |> order_by([event], asc: event.queue_sequence)
    |> lock("FOR UPDATE")
    |> repo.all()
    |> Enum.reject(&live_delivery_for_event?(repo, &1.id))
  end

  defp live_delivery_for_event?(repo, actor_event_id) do
    ActorEventDelivery
    |> where([delivery], delivery.actor_event_id == ^actor_event_id)
    |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
    |> repo.exists?()
  end

  defp complete_open_events_in_tx(repo, delegation_id, agent_uid, types, completed_at) do
    ActorEvent
    |> where([event], event.agent_uid == ^agent_uid)
    |> where([event], event.session_id == ^"subagent:#{delegation_id}")
    |> where([event], event.type in ^types)
    |> where([event], is_nil(event.completed_at))
    |> lock("FOR UPDATE")
    |> repo.all()
    |> Enum.reduce_while({:ok, :ok}, fn event, {:ok, :ok} ->
      case SignalsGateway.mark_actor_event_completed_in_tx(repo, event, completed_at) do
        {:ok, %ActorEvent{}} -> {:cont, {:ok, :ok}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp lock_open_actor_event(repo, actor_event_id) do
    ActorEvent
    |> where([event], event.id == ^actor_event_id)
    |> where([event], is_nil(event.completed_at))
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp insert_or_get_delegation(repo, attrs) do
    delegation = %Delegation{id: Ankole.Ecto.UUIDv7.autogenerate()}

    attrs =
      Map.put_new(
        attrs,
        "workdir",
        "/workspace/user-files/subagent/#{String.slice(delegation.id, 0, 8)}"
      )

    changeset = Delegation.creation_changeset(delegation, attrs)

    case repo.insert(changeset, on_conflict: :nothing) do
      {:ok, %Delegation{}} -> find_existing_delegation(repo, attrs)
      {:error, %Ecto.Changeset{}} = error -> error
    end
  end

  defp find_existing_delegation(repo, attrs) do
    Delegation
    |> where([delegation], delegation.agent_uid == ^Map.fetch!(attrs, "agent_uid"))
    |> where([delegation], delegation.session_id == ^Map.fetch!(attrs, "session_id"))
    |> where([delegation], delegation.tool_call_id == ^Map.fetch!(attrs, "tool_call_id"))
    |> repo.one()
    |> case do
      %Delegation{} = delegation -> {:ok, delegation}
      nil -> {:error, :subagent_delegation_not_found}
    end
  end

  defp append_dispatch_event(repo, %Delegation{} = delegation, now) do
    source_event_id = "subagent_delegation:#{delegation.id}:dispatch:#{delegation.attempts}"
    reply_route = delegation.reply_route || %{}

    SignalsGateway.append_actor_event_in_tx(repo, %{
      agent_uid: delegation.agent_uid,
      binding_name: Map.fetch!(reply_route, "binding_name"),
      session_id: "subagent:#{delegation.id}",
      source_event_id: source_event_id,
      signal_channel_id: Map.get(reply_route, "signal_channel_id"),
      provider_thread_id: Map.get(reply_route, "provider_thread_id"),
      source_entry_id: Map.get(reply_route, "source_entry_id"),
      type: "subagent.delegation.dispatch",
      available_at: now,
      payload: %{
        "specversion" => "1.0",
        "id" => source_event_id,
        "source" => "control-plane://subagent/delegation",
        "subject" => "subagent-delegation:#{delegation.id}",
        "time" => DateTime.to_iso8601(now),
        "type" => "subagent.delegation.dispatch",
        "data" =>
          Attrs.reject_nil_values(%{
            "delegation_id" => delegation.id,
            "parent_session_id" => delegation.session_id,
            "workdir" => delegation.workdir,
            "attempts" => delegation.attempts
          })
      }
    })
  end

  defp reply_route(attrs) do
    case Map.get(attrs, "reply_route") do
      %{} = route ->
        route = Attrs.normalize(route)

        case Attrs.text(route, "binding_name") do
          binding_name when is_binary(binding_name) ->
            {:ok, Map.put(route, "binding_name", binding_name)}

          nil ->
            {:error, :subagent_reply_route_binding_missing}
        end

      _value ->
        {:error, :invalid_subagent_reply_route}
    end
  end

  defp now, do: DateTime.utc_now(:microsecond)
end
