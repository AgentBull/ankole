defmodule Ankole.Sessions.Ambient do
  @moduledoc false
  use Ankole.Sessions.RunType

  require Ash.Query

  alias Ankole.Sessions.AmbientJudgment
  alias Ankole.BackgroundAgentJobs.Queries, as: BackgroundAgentJobQueries
  alias Ankole.Sessions.Queue
  alias Ankole.Signals.Signal
  alias Ankole.Signals.Binding
  alias Ankole.Conversations.Context

  def plan(_event, opts),
    do: {:ok, %{kind: :ambient, opts: Keyword.put_new(opts, :profile, "light")}}

  def prepare_input(event, now) do
    case resolve(event, now) do
      {:ok, %{status: :ambient_fresh, signal: event}} -> {:ok, event}
      {:ok, result} -> {:closed, result}
      error -> error
    end
  end

  def admit_in_tx(repo, event, _plan) do
    case AmbientJudgment |> Ash.Query.filter(signal_id == ^event.id) |> Ankole.Ash.read_one!() do
      %AmbientJudgment{action: action} when action in ["FOREGROUND_REPLY", "NEW_WORK"] ->
        {:ok, %{"ambient_work_candidates" => candidates_in_tx(repo, event)}}

      _ ->
        {:error, :ambient_turn_not_authorized}
    end
  end

  def tools(run, tools, hosted) do
    {tools, hosted} = super(run, tools, hosted)
    route = run.spec.request_context["ambient"] || %{}

    cond do
      route["action"] == "FOREGROUND_REPLY" ->
        {Enum.filter(tools, & &1["read_only"]),
         Enum.filter(hosted, &(&1["type"] in ["brain", "web_search"]))}

      route["authority"] == "NONE" and route["action"] == "NEW_WORK" ->
        {[], []}

      true ->
        {tools, hosted}
    end
  end

  @type session_key :: %{agent_uid: String.t(), session_id: String.t()}

  def prepare(run) do
    with %AmbientJudgment{action: action} = route <-
           AmbientJudgment
           |> Ash.Query.filter(signal_id == ^run.signal_id)
           |> Ankole.Ash.read_one!(),
         true <- action in ["FOREGROUND_REPLY", "NEW_WORK"] do
      spec = %{
        run.spec
        | request_context:
            Map.put(run.spec.request_context, "ambient", %{
              "action" => route.action,
              "authority" => route.authority,
              "handoff_job_id" => route.handoff_job_id
            })
      }

      %Signal{} = event = Ankole.Signals.get_signal!(run.signal_id)
      {:ok, {:prepare, %{run | event: event, delivered_event: event, spec: spec}}}
    else
      _ -> {:error, :ambient_turn_not_authorized}
    end
  end

  def resolve(%Signal{} = event, now),
    do: event |> Ankole.Sessions.resolve_ambient(now) |> Ankole.Errors.reason()

  @doc false
  def resolve_in_tx(repo, %Signal{} = event, now) do
    with :ok <- Ankole.Sessions.Admission.authorize_attempt_in_tx(repo, event),
         :ok <- Queue.lock_session_in_tx(repo, event.agent_uid, event.session_id) do
      case Ankole.Signals.lock_signal_in_tx(repo, event.id) do
        %Signal{status: :completed} = completed_event ->
          {:ok, %{status: :already_completed, signal: completed_event}}

        %Signal{status: live_status} = locked_event when live_status in [:queued, :running] ->
          cond do
            AmbientJudgment
            |> Ash.Query.filter(signal_id == ^locked_event.id)
            |> Ankole.Ash.read_one!() ->
              {:ok, %{status: :ambient_fresh, signal: locked_event}}

            locked_event.last_attempt_at ->
              resolve_attempted_event(repo, locked_event, now)

            true ->
              resolve_locked_event(repo, locked_event, now)
          end

        %Signal{} = unavailable_event ->
          {:ok, %{status: :ambient_unavailable, signal: unavailable_event}}

        nil ->
          {:ok, %{status: :idle}}
      end
    end
  end

  defp resolve_attempted_event(repo, locked_event, now) do
    case stale_reason(repo, locked_event, now) do
      nil ->
        {:ok, %{status: :ambient_fresh, signal: locked_event}}

      reason ->
        with {:ok, event} <- Queue.mark_event_completed_in_tx(repo, locked_event, now),
             do: {:ok, %{status: :ambient_superseded, signal: event, reason: reason}}
    end
  end

  defp resolve_locked_event(repo, event, now) do
    pending_events = lock_pending_ambient_events(repo, event)
    current_scene_fingerprint = current_scene_fingerprint(repo, event.conversation_id)

    classified =
      Enum.map(pending_events, fn pending_event ->
        {pending_event, stale_reason(repo, pending_event, now, current_scene_fingerprint)}
      end)

    latest_fresh_event =
      classified
      |> Enum.filter(fn {_event, reason} -> is_nil(reason) end)
      |> List.last()
      |> case do
        {%Signal{} = fresh_event, nil} -> fresh_event
        nil -> nil
      end

    latest_fresh_event_id = latest_fresh_event && latest_fresh_event.id

    superseded =
      Enum.flat_map(classified, fn
        {%Signal{id: id}, nil} when id == latest_fresh_event_id ->
          []

        {%Signal{} = pending_event, nil} ->
          [{pending_event, :newer_ambient_event}]

        {%Signal{} = pending_event, reason} ->
          [{pending_event, reason}]
      end)

    with {:ok, completed_by_id} <- complete_superseded(repo, superseded, now) do
      case Map.get(completed_by_id, event.id) do
        {%Signal{} = completed_event, reason} ->
          {:ok,
           %{
             status: :ambient_superseded,
             reason: reason,
             signal: completed_event,
             superseded_count: map_size(completed_by_id)
           }}

        nil when latest_fresh_event_id == event.id ->
          {:ok,
           %{
             status: :ambient_fresh,
             signal: latest_fresh_event,
             superseded_count: map_size(completed_by_id)
           }}

        nil ->
          {:ok, %{status: :ambient_unavailable, signal: event}}
      end
    end
  end

  defp lock_pending_ambient_events(repo, %Signal{} = event) do
    channel =
      if is_binary(event.conversation_id),
        do: event.conversation_id,
        else: [is_nil: true]

    Ankole.Signals.lock_signals_in_tx(repo,
      agent_uid: event.agent_uid,
      session_id: event.session_id,
      type: "im.message.may_intervene",
      producer: :kernel,
      status: [in: [:queued, :running]],
      last_attempt_at: [is_nil: true],
      conversation_id: channel
    )
  end

  defp complete_superseded(repo, superseded, now) do
    Enum.reduce_while(superseded, {:ok, %{}}, fn {event, reason}, {:ok, completed_by_id} ->
      case Queue.mark_event_completed_in_tx(repo, event, now) do
        {:ok, completed_event} ->
          completed_by_id = Map.put(completed_by_id, event.id, {completed_event, reason})
          {:cont, {:ok, completed_by_id}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  @doc "Gives the work candidates of an ambient input outside a transaction."
  def candidates(event), do: candidates_in_tx(Ankole.Repo, event)

  def candidates_in_tx(repo, event) do
    BackgroundAgentJobQueries.ambient_candidates_in_tx(
      repo,
      event.agent_uid,
      event.session_id,
      event.conversation_id,
      event.reply_binding_name
    )
    |> work_candidates_payload()
  end

  defp work_candidates_payload(%{complete: complete, jobs: jobs}) do
    %{
      "complete" => complete,
      "jobs" =>
        Enum.map(jobs, fn job ->
          %{
            "job_id" => Integer.to_string(job.job_id),
            "title" => job.title,
            "status" => to_string(job.status),
            "task_excerpt" => job.task_excerpt
          }
        end)
    }
  end

  defp stale_reason(repo, %Signal{} = event, now) do
    current_scene_fingerprint = current_scene_fingerprint(repo, event.conversation_id)
    stale_reason(repo, event, now, current_scene_fingerprint)
  end

  @doc false
  @spec ensure_fresh_in_tx(module(), Signal.t(), DateTime.t()) ::
          :ok | {:error, {:ambient_stale, atom()}}
  def ensure_fresh_in_tx(repo, %Signal{} = event, %DateTime{} = now) do
    case stale_reason(repo, event, now) do
      nil -> :ok
      reason -> {:error, {:ambient_stale, reason}}
    end
  end

  defp stale_reason(repo, %Signal{} = event, now, current_scene_fingerprint) do
    ambient_batch = event.data["ambient_batch"]
    stored_fingerprint = map_value(ambient_batch, "scene_fingerprint")
    expires_at = ambient_batch |> map_value("expires_at") |> Ankole.Attrs.parse_datetime()

    cond do
      not current_binding_allows_intervention?(repo, event) ->
        :binding_policy_changed

      not is_binary(stored_fingerprint) or is_nil(expires_at) ->
        :missing_freshness_snapshot

      DateTime.compare(now, expires_at) != :lt ->
        :expired

      not is_binary(event.conversation_id) ->
        :missing_signal_channel

      current_scene_fingerprint != stored_fingerprint ->
        :scene_changed

      true ->
        nil
    end
  end

  defp current_scene_fingerprint(repo, conversation_id) when is_binary(conversation_id),
    do: Context.ambient_scene_fingerprint(repo, conversation_id)

  defp current_scene_fingerprint(_repo, _conversation_id), do: nil

  defp current_binding_allows_intervention?(repo, %Signal{} = event) do
    binding =
      is_binary(event.reply_binding_name) &&
        Ankole.Signals.share_binding_in_tx(repo, event.agent_uid, event.reply_binding_name)

    case binding do
      %Binding{
        enabled: true,
        unavailable_reason: nil,
        unaddressed_group_message_policy: :may_intervene
      } ->
        true

      _binding ->
        false
    end
  end

  defp map_value(map, key) when is_map(map), do: Map.get(map, key)
  defp map_value(_value, _key), do: nil
end
