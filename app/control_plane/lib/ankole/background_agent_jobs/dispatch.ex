defmodule Ankole.BackgroundAgentJobs.Dispatch do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Adapters.SQL

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.AIAgent.Library.AgentPlugins.Contract
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Attrs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.RuntimeEvents
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery

  @supported_create_fields ~w(
    agent_uid
    background
    metadata
    model
    notes
    owner_session_id
    agent_plugin_ids
    reasoning_effort
    reply_route
    skill_names
    source_actor_event_id
    source_tool_call_id
    task
    title
    workspace_mounts
  )

  @spec create_with_dispatch(map()) ::
          {:ok, %{job: Job.t(), dispatch_event: ActorEvent.t()}} | {:error, term()}
  def create_with_dispatch(attrs) when is_map(attrs) do
    now = now()

    with attrs when is_map(attrs) <- Attrs.normalize(attrs),
         :ok <- reject_unsupported_create_fields(attrs),
         {:ok, agent_uid} <- Principals.normalize_uid(Attrs.text(attrs, "agent_uid")) do
      attrs = Map.put(attrs, "agent_uid", agent_uid)

      case find_existing_job(Repo, attrs) do
        {:ok, job} -> existing_job_result(Repo, job)
        {:error, :background_agent_job_not_found} -> prepare_new_job(attrs, agent_uid, now)
      end
    end
  end

  defp prepare_new_job(attrs, agent_uid, now) do
    with {:ok, reply_route} <- reply_route(attrs),
         {:ok, codex_account_id} <- codex_account_id(agent_uid) do
      attrs
      |> Map.put("reply_route", reply_route)
      |> Map.put("codex_account_id", codex_account_id)
      |> create_new_job(agent_uid, now)
    end
  end

  defp create_new_job(attrs, agent_uid, now) do
    with {:ok, agent_plugin_ids} <- validate_agent_plugin_ids(agent_uid, attrs),
         {:ok, skill_names} <- resolve_skill_names(agent_uid, attrs),
         job_id <- Ankole.Ecto.UUIDv7.autogenerate(),
         {:ok, workspace_mounts, metadata} <- resolve_workspace_mounts(attrs, job_id) do
      attrs =
        attrs
        |> Map.put("agent_plugin_ids", agent_plugin_ids)
        |> Map.put("skill_names", skill_names)
        |> Map.put("workspace_mounts", workspace_mounts)
        |> Map.put("metadata", metadata)
        |> Map.put_new("status", "queued")
        |> Map.put_new("attempts", 0)
        |> Map.put_new("queued_at", now)
        |> Map.put_new("result", %{})
        |> Map.put_new("error", %{})

      persist_job(job_id, attrs, now)
    end
  end

  defp persist_job(job_id, attrs, now) do
    Repo.transact(fn repo ->
      with :ok <- lock_start_idempotency(repo, attrs) do
        case find_existing_job(repo, attrs) do
          {:ok, job} ->
            existing_job_result(repo, job)

          {:error, :background_agent_job_not_found} ->
            with {:ok, job} <- repo.insert(Job.creation_changeset(%Job{id: job_id}, attrs)),
                 {:ok, dispatch_event} <- append_dispatch_event(repo, job, now) do
              {:ok, %{job: job, dispatch_event: dispatch_event}}
            end
        end
      end
    end)
  end

  defp existing_job_result(repo, %Job{} = job) do
    case find_dispatch_event(repo, job) do
      %ActorEvent{} = dispatch_event ->
        {:ok, %{job: job, dispatch_event: dispatch_event}}

      nil ->
        {:error, :background_agent_job_dispatch_event_not_found}
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
  def complete_open_dispatch(job_id, agent_uid) do
    Repo.transact(fn repo ->
      complete_open_events_in_tx(
        repo,
        job_id,
        agent_uid,
        ["background_agent_job.dispatch"],
        now()
      )
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def complete_all_open_events_in_tx(repo, job_id, agent_uid, %DateTime{} = completed_at) do
    complete_open_events_in_tx(
      repo,
      job_id,
      agent_uid,
      ["background_agent_job.dispatch", "command.steer"],
      completed_at
    )
  end

  @doc false
  def pending_steer_events(job_id, agent_uid, excluded_event_id) do
    Repo.transact(fn repo ->
      {:ok, pending_steer_events_in_tx(repo, job_id, agent_uid, excluded_event_id)}
    end)
  end

  defp pending_steer_events_in_tx(repo, job_id, agent_uid, excluded_event_id) do
    ActorEvent
    |> where([event], event.agent_uid == ^agent_uid)
    |> where([event], event.session_id == ^BackgroundAgentJobs.job_session_id(job_id))
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

  defp complete_open_events_in_tx(repo, job_id, agent_uid, types, completed_at) do
    ActorEvent
    |> where([event], event.agent_uid == ^agent_uid)
    |> where([event], event.session_id == ^BackgroundAgentJobs.job_session_id(job_id))
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

  defp find_existing_job(repo, attrs) do
    case {
      Attrs.text(attrs, "agent_uid"),
      Attrs.text(attrs, "owner_session_id"),
      Attrs.text(attrs, "source_tool_call_id")
    } do
      {agent_uid, owner_session_id, source_tool_call_id}
      when is_binary(agent_uid) and is_binary(owner_session_id) and is_binary(source_tool_call_id) ->
        Job
        |> where([job], job.agent_uid == ^agent_uid)
        |> where([job], job.owner_session_id == ^owner_session_id)
        |> where([job], job.source_tool_call_id == ^source_tool_call_id)
        |> repo.one()
        |> case do
          %Job{} = job -> {:ok, job}
          nil -> {:error, :background_agent_job_not_found}
        end

      _idempotency_key ->
        {:error, :background_agent_job_not_found}
    end
  end

  defp lock_start_idempotency(repo, attrs) do
    lock_key =
      [
        "background_agent_job:start",
        Attrs.text(attrs, "agent_uid"),
        Attrs.text(attrs, "owner_session_id"),
        Attrs.text(attrs, "source_tool_call_id")
      ]
      |> Enum.join(":")

    case SQL.query(repo, "SELECT pg_advisory_xact_lock(hashtext($1::text))", [lock_key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_dispatch_event(repo, %Job{} = job, now) do
    source_event_id = dispatch_source_event_id(job)
    reply_route = job.reply_route || %{}

    SignalsGateway.append_actor_event_in_tx(repo, %{
      agent_uid: job.agent_uid,
      binding_name: Map.fetch!(reply_route, "binding_name"),
      session_id: BackgroundAgentJobs.job_session_id(job.id),
      source_event_id: source_event_id,
      signal_channel_id: Map.get(reply_route, "signal_channel_id"),
      provider_thread_id: Map.get(reply_route, "provider_thread_id"),
      type: "background_agent_job.dispatch",
      available_at: now,
      payload: %{
        "specversion" => "1.0",
        "id" => source_event_id,
        "source" => "control-plane://background-agent-job",
        "subject" => "background-agent-job:#{job.id}",
        "time" => DateTime.to_iso8601(now),
        "type" => "background_agent_job.dispatch",
        "data" =>
          Attrs.reject_nil_values(%{
            "job_id" => job.id,
            "owner_session_id" => job.owner_session_id,
            "agent_plugin_ids" => job.agent_plugin_ids,
            "workspace_mounts" => job.workspace_mounts,
            "attempts" => job.attempts
          })
      }
    })
  end

  defp find_dispatch_event(repo, %Job{} = job) do
    reply_route = job.reply_route || %{}

    ActorEvent
    |> where([event], event.agent_uid == ^job.agent_uid)
    |> where([event], event.binding_name == ^Map.fetch!(reply_route, "binding_name"))
    |> where([event], event.source_event_id == ^dispatch_source_event_id(job))
    |> repo.one()
  end

  defp dispatch_source_event_id(%Job{} = job),
    do: "background_agent_job:#{job.id}:dispatch"

  defp reply_route(attrs) do
    case Map.get(attrs, "reply_route") do
      %{} = route ->
        route = Attrs.normalize(route)

        case Attrs.text(route, "binding_name") do
          binding_name when is_binary(binding_name) ->
            {:ok, Map.put(route, "binding_name", binding_name)}

          nil ->
            {:error, :background_agent_job_reply_route_binding_missing}
        end

      _value ->
        {:error, :invalid_background_agent_job_reply_route}
    end
  end

  defp reject_unsupported_create_fields(attrs) do
    case Map.keys(attrs) |> Enum.reject(&(&1 in @supported_create_fields)) |> Enum.sort() do
      [] -> :ok
      fields -> {:error, {:unsupported_background_agent_job_create_fields, fields}}
    end
  end

  defp validate_agent_plugin_ids(agent_uid, attrs) do
    AgentPlugins.validate_selection_for_agent(
      agent_uid,
      Map.get(attrs, "agent_plugin_ids", [])
    )
  end

  defp resolve_skill_names(agent_uid, attrs) do
    requested =
      if Map.has_key?(attrs, "skill_names"), do: Map.get(attrs, "skill_names"), else: nil

    Library.resolve_job_skill_names(agent_uid, requested)
  end

  defp resolve_workspace_mounts(attrs, job_id) do
    case Map.get(attrs, "metadata", %{}) do
      %{} = metadata ->
        metadata = Map.put(metadata, "managed_background_agent_job_root", true)

        case Map.fetch(attrs, "workspace_mounts") do
          {:ok, mounts} ->
            with :ok <- Contract.validate_workspace_mounts(mounts) do
              {:ok, mounts, metadata}
            end

          :error ->
            mounts = [
              %{
                "id" => "workspace",
                "source" => "/workspace/user-files/background-agent-jobs/#{job_id}/workspace",
                "access" => "read_write"
              }
            ]

            metadata = Map.put(metadata, "managed_workspace_mount_ids", ["workspace"])

            {:ok, mounts, metadata}
        end

      _value ->
        {:error, :invalid_background_agent_job_metadata}
    end
  end

  defp now, do: DateTime.utc_now(:microsecond)
end
