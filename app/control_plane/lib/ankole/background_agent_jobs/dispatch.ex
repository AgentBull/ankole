defmodule Ankole.BackgroundAgentJobs.Dispatch do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Adapters.SQL

  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Attrs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.Signals.Signal
  alias Ankole.Workflow

  @supported_create_fields ~w(
    agent_uid
    created_by
    metadata
    model_profile
    owner_session_id
    reply_route
    source_signal_id
    source_tool_call_id
    task
    title
    workspace_template_id
  )

  @supported_respawn_fields ~w(
    agent_uid
    message
    metadata
    owner_session_id
    reply_route
    source_signal_id
    source_tool_call_id
  )

  @spec create_with_dispatch(map()) ::
          {:ok, %{job: Job.t(), dispatch_event: Signal.t()}} | {:error, term()}
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

  @spec respawn_with_dispatch(pos_integer(), map()) ::
          {:ok, %{job: Job.t(), dispatch_event: Signal.t()}} | {:error, term()}
  def respawn_with_dispatch(source_job_id, attrs)
      when is_integer(source_job_id) and source_job_id > 0 and is_map(attrs) do
    now = now()

    with attrs when is_map(attrs) <- Attrs.normalize(attrs),
         :ok <- reject_unsupported_respawn_fields(attrs),
         {:ok, agent_uid} <- Principals.normalize_uid(Attrs.text(attrs, "agent_uid")) do
      attrs = Map.put(attrs, "agent_uid", agent_uid)

      case find_existing_job(Repo, attrs) do
        {:ok, job} ->
          existing_job_result(Repo, job)

        {:error, :background_agent_job_not_found} ->
          prepare_respawn(source_job_id, attrs, agent_uid, now)
      end
    end
  end

  defp prepare_new_job(attrs, agent_uid, now) do
    with {:ok, reply_route} <- reply_route(attrs),
         {:ok, model_profile} <- requested_model_profile(agent_uid, attrs) do
      attrs
      |> Map.put("reply_route", reply_route)
      |> Map.put("model_profile", model_profile)
      |> create_new_job(agent_uid, now)
    end
  end

  defp create_new_job(attrs, agent_uid, now) do
    with {:ok, workspace_template_id} <- validate_workspace_template_id(agent_uid, attrs),
         {:ok, metadata} <- job_metadata(attrs, true) do
      attrs =
        attrs
        |> Map.put("workspace_template_id", workspace_template_id)
        |> Map.put("metadata", metadata)
        |> Map.put_new("status", "queued")
        |> Map.put_new("attempts", 0)
        |> Map.put_new("queued_at", now)
        |> Map.put_new("result", %{})
        |> Map.put_new("error", %{})

      persist_job(attrs, now)
    end
  end

  defp prepare_respawn(source_job_id, attrs, agent_uid, now) do
    with {:ok, reply_route} <- reply_route(attrs),
         %Job{} = source_job <- BackgroundAgentJobs.get_job_for_agent(source_job_id, agent_uid),
         {:ok, model_profile} <- available_model_profile(agent_uid, source_job.model_profile),
         {:ok, metadata} <- job_metadata(attrs, false) do
      attrs =
        attrs
        |> Map.put("reply_route", reply_route)
        |> Map.put("model_profile", model_profile)
        |> Map.put("metadata", metadata)

      persist_respawn(source_job_id, attrs, now)
    else
      nil -> {:error, :job_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp requested_model_profile(agent_uid, attrs) do
    case Attrs.text(attrs, "model_profile") do
      nil -> available_model_profile(agent_uid, "coding")
      profile -> available_custom_model_profile(agent_uid, profile)
    end
  end

  defp available_custom_model_profile(agent_uid, profile) do
    with {:ok, custom_profile} <- ModelProfiles.get_custom_model_profile(agent_uid, profile),
         normalized_profile <- Map.fetch!(custom_profile, "profile"),
         {:ok, _runtime} <- ModelProfiles.resolve_runtime_profile(agent_uid, normalized_profile) do
      {:ok, normalized_profile}
    end
  end

  defp available_model_profile(agent_uid, profile) do
    with {:ok, runtime} <- ModelProfiles.resolve_runtime_profile(agent_uid, profile) do
      {:ok, Map.fetch!(runtime, "profile")}
    end
  end

  defp persist_job(attrs, now) do
    Repo.transact(fn repo ->
      attrs = Ankole.Principals.WorkAccess.inherit(repo, attrs)

      with :ok <- Ankole.Tenants.check_work_admission(Repo.tenant_id!()),
           :ok <- Ankole.Principals.WorkAccess.check_attrs_in_tx(repo, attrs),
           :ok <- lock_start_idempotency(repo, attrs) do
        case find_existing_job(repo, attrs) do
          {:ok, job} ->
            existing_job_result(repo, job)

          {:error, :background_agent_job_not_found} ->
            with :ok <-
                   Workflow.authorize_delegated_job_owner_in_tx(
                     repo,
                     attrs["agent_uid"],
                     attrs["owner_session_id"]
                   ),
                 {:ok, job_id} <- next_job_id(repo),
                 attrs <- Map.put(attrs, "workspace_owner_job_id", job_id),
                 {:ok, attrs} <- pin_owner_conversation(repo, attrs),
                 {:ok, job} <- repo.insert(Job.creation_changeset(%Job{id: job_id}, attrs)),
                 {:ok, dispatch_event} <- append_dispatch_event(repo, job, now) do
              {:ok, %{job: job, dispatch_event: dispatch_event}}
            end
        end
      end
    end)
  end

  defp persist_respawn(source_job_id, attrs, now) do
    Repo.transact(fn repo ->
      attrs = Ankole.Principals.WorkAccess.inherit(repo, attrs)

      with :ok <- Ankole.Tenants.check_work_admission(Repo.tenant_id!()),
           :ok <- Ankole.Principals.WorkAccess.check_attrs_in_tx(repo, attrs),
           :ok <- lock_start_idempotency(repo, attrs) do
        case find_existing_job(repo, attrs) do
          {:ok, job} ->
            existing_job_result(repo, job)

          {:error, :background_agent_job_not_found} ->
            with {:ok, source_job} <-
                   lock_respawn_source(repo, source_job_id, attrs["agent_uid"]),
                 :ok <- validate_respawn_source(source_job),
                 :ok <- ensure_no_successor(repo, source_job),
                 :ok <-
                   Workflow.authorize_delegated_job_owner_in_tx(
                     repo,
                     attrs["agent_uid"],
                     attrs["owner_session_id"]
                   ),
                 attrs <- respawn_job_attrs(attrs, source_job, now),
                 {:ok, attrs} <- pin_owner_conversation(repo, attrs),
                 {:ok, job} <- repo.insert(Job.creation_changeset(%Job{}, attrs)),
                 {:ok, dispatch_event} <- append_dispatch_event(repo, job, now) do
              {:ok, %{job: job, dispatch_event: dispatch_event}}
            end
        end
      end
    end)
  end

  defp lock_respawn_source(repo, source_job_id, agent_uid) do
    Job
    |> where([job], job.id == ^source_job_id)
    |> where([job], job.agent_uid == ^agent_uid)
    |> lock("FOR UPDATE")
    |> repo.one()
    |> case do
      %Job{} = job -> {:ok, job}
      nil -> {:error, :job_not_found}
    end
  end

  defp validate_respawn_source(%Job{} = job) do
    cond do
      job.status not in Job.terminal_statuses() ->
        {:error, {:background_agent_job_not_terminal, job.status}}

      not is_binary(job.runtime_thread_id) ->
        {:error, :background_agent_job_runtime_thread_missing}

      not is_integer(job.workspace_owner_job_id) ->
        {:error, :background_agent_job_workspace_owner_missing}

      true ->
        :ok
    end
  end

  defp ensure_no_successor(repo, %Job{} = source_job) do
    Job
    |> where([job], job.continued_from_job_id == ^source_job.id)
    |> select([job], job.id)
    |> repo.one()
    |> case do
      nil -> :ok
      successor_id -> {:error, {:background_agent_job_already_respawned, successor_id}}
    end
  end

  defp respawn_job_attrs(attrs, source_job, now) do
    metadata = Map.get(attrs, "metadata", %{})

    metadata =
      if source_job.metadata["legacy_thread_replay"] == true,
        do: Map.put(metadata, "legacy_thread_replay", true),
        else: Map.delete(metadata, "legacy_thread_replay")

    attrs
    |> Map.put("metadata", metadata)
    |> Map.delete("message")
    |> Map.put("title", source_job.title)
    |> Map.put("task", Map.get(attrs, "message"))
    |> Map.put("runtime_thread_id", source_job.runtime_thread_id)
    |> Map.put("continued_from_job_id", source_job.id)
    |> Map.put("workspace_owner_job_id", source_job.workspace_owner_job_id)
    |> Map.put("workspace_template_id", nil)
    |> Map.put("model_profile", source_job.model_profile)
    |> Map.put("status", "queued")
    |> Map.put("attempts", 0)
    |> Map.put("queued_at", now)
    |> Map.put("result", %{})
    |> Map.put("error", %{})
  end

  defp existing_job_result(repo, %Job{} = job) do
    case find_dispatch_event(repo, job) do
      %Signal{} = dispatch_event ->
        {:ok, %{job: job, dispatch_event: dispatch_event}}

      nil ->
        {:error, :background_agent_job_dispatch_event_not_found}
    end
  end

  @spec defer_signal(Signal.t(), DateTime.t()) ::
          {:ok, Signal.t()} | {:error, term()}
  def defer_signal(%Signal{} = signal, %DateTime{} = available_at) do
    Repo.transact(fn repo ->
      with %Signal{} = signal <- lock_open_signal(repo, signal.id),
           {:ok, signal} <-
             signal
             |> Signal.changeset(%{available_at: available_at})
             |> repo.update(),
           :ok <-
             Ankole.Sessions.Jobs.EnsureDriver.enqueue_in_tx(
               repo,
               %{agent_uid: signal.agent_uid, session_id: signal.session_id},
               available_at
             ) do
        {:ok, signal}
      else
        nil -> {:ok, signal}
        {:error, _reason} = error -> error
      end
    end)
  end

  @spec complete_signal(Signal.t()) :: {:ok, Signal.t()} | {:error, term()}
  def complete_signal(%Signal{} = signal) do
    Repo.transact(fn repo ->
      case lock_open_signal(repo, signal.id) do
        %Signal{} = event ->
          Ankole.Sessions.Queue.mark_event_completed_in_tx(repo, event, now())

        nil ->
          {:ok, signal}
      end
    end)
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
  @spec open_steer_events_in_tx(module(), pos_integer(), String.t()) :: [Signal.t()]
  def open_steer_events_in_tx(repo, job_id, agent_uid) do
    Signal
    |> where([event], event.agent_uid == ^agent_uid)
    |> where([event], event.session_id == ^BackgroundAgentJobs.job_session_id(job_id))
    |> where([event], event.type == "command.steer")
    |> where([event], event.input_state == "open")
    |> where([event], is_nil(event.completed_at))
    |> order_by([event], asc: event.queue_sequence)
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  # One successor carries every open steer in arrival order. The successor is
  # an ordinary respawn row: same Codex thread, `continued_from_job_id` set, and
  # the steer texts joined as its task, so the one-successor-per-source unique
  # index also makes commit replays idempotent.
  @doc false
  @spec seed_steer_successor_in_tx(module(), Job.t(), [Signal.t()], DateTime.t()) ::
          {:ok, %{job: Job.t(), dispatch_event: Signal.t()}} | {:error, term()}
  def seed_steer_successor_in_tx(repo, %Job{} = source_job, [first | _rest] = steers, now) do
    task = steers |> Enum.map(&steer_text/1) |> Enum.reject(&is_nil/1) |> Enum.join("\n\n")

    with :ok <- ensure_seedable_task(task),
         :ok <- ensure_no_successor(repo, source_job),
         :ok <-
           Workflow.authorize_delegated_job_owner_in_tx(
             repo,
             source_job.agent_uid,
             source_job.owner_session_id
           ),
         attrs =
           %{
             "agent_uid" => source_job.agent_uid,
             "owner_session_id" => source_job.owner_session_id,
             "source_signal_id" => first.id,
             "source_tool_call_id" => "steer-successor:#{first.id}",
             "reply_route" => source_job.reply_route || %{},
             "message" => task,
             "metadata" => %{"seeded_from_steer" => true},
             "model_profile" => source_job.model_profile
           }
           |> respawn_job_attrs(source_job, now)
           |> Ankole.Principals.WorkAccess.merge(first),
         {:ok, attrs} <- pin_owner_conversation(repo, attrs),
         {:ok, job} <- repo.insert(Job.creation_changeset(%Job{}, attrs)),
         {:ok, dispatch_event} <- append_dispatch_event(repo, job, now) do
      {:ok, %{job: job, dispatch_event: dispatch_event}}
    end
  end

  defp ensure_seedable_task(""), do: {:error, :background_agent_job_steer_text_missing}
  defp ensure_seedable_task(task) when is_binary(task), do: :ok

  defp steer_text(%Signal{data: data}) do
    case get_in(data, ["command", "argsText"]) do
      text when is_binary(text) and text != "" -> text
      _missing -> nil
    end
  end

  defp complete_open_events_in_tx(repo, job_id, agent_uid, types, completed_at) do
    Signal
    |> where([event], event.agent_uid == ^agent_uid)
    |> where([event], event.session_id == ^BackgroundAgentJobs.job_session_id(job_id))
    |> where([event], event.type in ^types)
    |> where([event], is_nil(event.completed_at))
    |> lock("FOR UPDATE")
    |> repo.all()
    |> Enum.reduce_while({:ok, :ok}, fn event, {:ok, :ok} ->
      case Ankole.Sessions.Queue.mark_event_completed_in_tx(repo, event, completed_at) do
        {:ok, %Signal{}} -> {:cont, {:ok, :ok}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp lock_open_signal(repo, signal_id) do
    Signal
    |> where([event], event.id == ^signal_id)
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

    Ankole.Signals.accept_in_tx(repo, %{
      producer: :kernel,
      source: "control-plane://background-agent-job",
      id: source_event_id,
      type: "background_agent_job.dispatch",
      subject: "background-agent-job:#{job.id}",
      time: DateTime.to_iso8601(now),
      available_at: now,
      target: %{agent_uid: job.agent_uid, session_id: BackgroundAgentJobs.job_session_id(job.id)},
      sender: nil,
      authorization: Ankole.Principals.WorkAccess.fields(job),
      reply_route: %{
        binding_name: Map.get(reply_route, "binding_name"),
        conversation_id: Map.get(reply_route, "conversation_id"),
        provider_thread_id: Map.get(reply_route, "provider_thread_id"),
        provider_message_id: nil
      },
      data:
        Attrs.reject_nil_values(%{
          "job_id" => job.id,
          "continued_from_job_id" => job.continued_from_job_id,
          "owner_session_id" => job.owner_session_id,
          "workspace_owner_job_id" => job.workspace_owner_job_id,
          "workspace_template_id" => job.workspace_template_id,
          "model_profile" => job.model_profile,
          "attempts" => job.attempts
        })
    })
  end

  defp find_dispatch_event(repo, %Job{} = job) do
    Signal
    |> where([event], event.agent_uid == ^job.agent_uid)
    |> where([event], event.source == "control-plane://background-agent-job")
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
            case Ecto.UUID.cast(Map.get(route, "conversation_id")) do
              {:ok, id} -> {:ok, Map.put(route, "conversation_id", id)}
              :error -> {:error, :background_agent_job_reply_route_binding_missing}
            end
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

  defp reject_unsupported_respawn_fields(attrs) do
    case Map.keys(attrs) |> Enum.reject(&(&1 in @supported_respawn_fields)) |> Enum.sort() do
      [] -> :ok
      fields -> {:error, {:unsupported_background_agent_job_respawn_fields, fields}}
    end
  end

  defp next_job_id(repo) do
    case SQL.query(
           repo,
           "SELECT nextval(pg_get_serial_sequence('background_agent_jobs', 'id'))",
           []
         ) do
      {:ok, %{rows: [[job_id]]}}
      when is_integer(job_id) and job_id in 1000..9_007_199_254_740_991 ->
        {:ok, job_id}

      {:ok, _result} ->
        {:error, :invalid_background_agent_job_sequence_value}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_workspace_template_id(agent_uid, attrs) do
    AgentPlugins.validate_workspace_template_for_agent(
      agent_uid,
      Attrs.text(attrs, "workspace_template_id")
    )
  end

  defp job_metadata(attrs, manages_workspace_root) when is_boolean(manages_workspace_root) do
    case Map.get(attrs, "metadata", %{}) do
      %{} = metadata ->
        {:ok,
         metadata
         |> Map.delete("applied_source_signal_id")
         |> Map.put("managed_background_agent_job_root", manages_workspace_root)}

      _value ->
        {:error, :invalid_background_agent_job_metadata}
    end
  end

  # Admission resolves the Job context from metadata.owner_conversation_id.
  # Creation pins the owner session's conversation on every insert path.
  # Callers do not supply this identity.
  defp pin_owner_conversation(repo, attrs) do
    case Attrs.text(attrs, "owner_session_id") do
      session_id when is_binary(session_id) ->
        with {:ok, conversation} <-
               AIGateway.ensure_conversation_in_tx(
                 repo,
                 Attrs.text(attrs, "agent_uid"),
                 session_id
               ) do
          metadata = Map.get(attrs, "metadata", %{})

          {:ok,
           Map.put(attrs, "metadata", Map.put(metadata, "owner_conversation_id", conversation.id))}
        end

      nil ->
        {:error, :background_agent_job_owner_session_missing}
    end
  end

  defp now, do: DateTime.utc_now(:microsecond)
end
