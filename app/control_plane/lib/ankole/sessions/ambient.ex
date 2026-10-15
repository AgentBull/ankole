defmodule Ankole.Sessions.Ambient do
  @moduledoc false
  use Ankole.Sessions.RunType

  import Ecto.Query, warn: false

  alias Ankole.Repo
  alias Ankole.AIGateway
  alias Ankole.Sessions.Fence
  alias Ankole.Sessions.Machine
  alias Ankole.Sessions.Model
  alias Ankole.Sessions.Prompt
  alias Ankole.Sessions.ToolArguments
  alias Ankole.Sessions.AmbientCuration
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

  def admit_in_tx(repo, event, _plan),
    do: {:ok, %{"ambient_work_candidates" => candidates_in_tx(repo, event)}}

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
    with {:ok, route} <- route(run) do
      if route.action in ["NOOP", "HANDOFF"] do
        {:ok, {:ambient_skip, run}}
      else
        spec =
          %{
            run.spec
            | request_context:
                Map.put(run.spec.request_context, "ambient", %{
                  "action" => route.action,
                  "authority" => route.authority,
                  "handoff_job_id" => route.handoff_job_id
                })
          }

        event = Repo.get!(Signal, run.signal_id)

        delivered = event

        {:ok, {:prepare, %{run | event: event, delivered_event: delivered, spec: spec}}}
      end
    end
  end

  defp route(run) do
    case Repo.get(AmbientJudgment, run.signal_id) do
      %AmbientJudgment{} = judgment ->
        {:ok, Map.take(judgment, [:action, :authority, :handoff_job_id])}

      nil ->
        recognize(run)
    end
  end

  defp recognize(run) do
    {input, schema, delta, orders?} = observation(run)
    model = run.spec.model_ref

    request = %{
      "model" => Model.selector(model),
      "provider_options" => model["provider_options"] || %{},
      "instructions" => Prompt.ambient_system(run),
      "input" => [Machine.user(input)],
      "max_output_tokens" => 300,
      "temperature" => 0,
      "text" => %{
        "format" => %{
          "type" => "json_schema",
          "name" => "ambient_intent_route",
          "strict" => true,
          "schema" => schema
        }
      }
    }

    with {:ok, %{body: body}} <-
           AIGateway.create_response(run.agent_uid, request,
             subject_type: "agent",
             caller: "ambient",
             request_context: run.spec.request_context
           ),
         {:ok, text} <- AIGateway.completed_output_text(body),
         value = decision(text, schema, delta, orders?),
         decision = %{
           action: value["action"],
           authority: value["authority"],
           handoff_job_id: value["handoff_job_id"] && String.to_integer(value["handoff_job_id"]),
           reason: value["reason"],
           asked_by_message_id: value["asked_by_message_id"],
           asked_by_state: value["asked_by_state"]
         },
         {:ok, route} <-
           AmbientCuration.record_judgment(
             %{agent_uid: run.agent_uid, session_id: run.session_id},
             run.signal_id,
             decision,
             authorize_in_tx: &Fence.check_in_tx(&1, run, :share)
           ) do
      {:ok, route}
    end
  end

  def observation(run, now \\ DateTime.utc_now(:microsecond)) do
    data = run.event.data
    zone = run.context.conversation.timezone || "UTC"
    current = local_time(now, zone, false)
    {delta, backdrop} = observation_transcript(data, zone, now)

    orders = Ankole.Sessions.Prompt.Input.standing_orders(run.event) || ""
    candidates = run.spec.request_context["ambient_work_candidates"] || %{}
    jobs = Enum.take(candidates["jobs"] || [], 8)

    complete? =
      candidates["complete"] == true and
        Enum.any?(data["observed_messages"] || [], &(is_map(&1) and &1["text"] not in [nil, ""]))

    job_ids = if complete?, do: Enum.map(jobs, & &1["job_id"]), else: []

    asked_ids =
      delta
      |> Enum.filter(&(&1.role == "human" and is_binary(&1.id)))
      |> Enum.map(& &1.id)
      |> Enum.uniq()

    actions =
      if job_ids == [],
        do: ~w(NOOP FOREGROUND_REPLY NEW_WORK),
        else: ~w(NOOP FOREGROUND_REPLY NEW_WORK HANDOFF)

    authorities =
      ["NONE"] ++
        if(asked_ids == [], do: [], else: ["EXPLICIT_REQUEST"]) ++
        if(orders == "", do: [], else: ["STANDING_ORDER"])

    schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ~w(action authority handoff_job_id asked_by reason),
      "properties" => %{
        "action" => %{"type" => "string", "enum" => actions},
        "authority" => %{"type" => "string", "enum" => authorities},
        "handoff_job_id" => nullable_ids(job_ids),
        "asked_by" => nullable_ids(asked_ids),
        "reason" => %{"type" => "string", "minLength" => 1, "maxLength" => 300}
      }
    }

    origin = run.context.conversation.origin_channel || %{}

    work = active_work_section(jobs, complete?)

    input =
      [
        Enum.join(
          [
            "<runtime_context>",
            "current_time: #{current}",
            "timezone: #{zone}",
            "platform: #{platform(origin.adapter)}",
            "group_name: #{origin.label || "unknown group"}",
            "</runtime_context>"
          ],
          "\n"
        ),
        if(orders == "",
          do: "Standing Orders: none.",
          else: "Standing Orders (trusted operator policy for this room):\n#{orders}"
        ),
        work,
        if(backdrop != [],
          do:
            Enum.join(
              [
                "Earlier Context (already reviewed; use only to understand New Messages):"
                | Enum.map(backdrop, &transcript_line(&1, false))
              ],
              "\n"
            )
        ),
        Enum.join(
          [
            "New Messages (not yet judged; classify only these):"
            | if(delta == [],
                do: ["- No visible group messages were provided."],
                else: Enum.map(delta, &transcript_line(&1, true))
              )
          ],
          "\n"
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    {input, schema, delta, orders != ""}
  end

  def decision(text, schema, delta, orders?) do
    invalid = %{
      "action" => "NOOP",
      "authority" => "NONE",
      "reason" => "The structured ambient route was invalid, so the Agent stayed silent."
    }

    with {:ok, value, _} <- ToolArguments.parse(text),
         value =
           Map.update(value, "reason", nil, &if(is_binary(&1), do: String.trim(&1), else: &1)),
         {:ok, value} <- ToolArguments.validate(schema, value),
         true <- value["action"] == "HANDOFF" == is_binary(value["handoff_job_id"]) do
      humans = Enum.filter(delta, &(&1.role == "human" and String.trim(&1.text) != ""))
      asked = Enum.find(humans, &(&1.id == value["asked_by"]))
      newest = List.last(humans)
      accepted? = asked && newest && asked.speaker == newest.speaker

      authority =
        cond do
          value["action"] != "NEW_WORK" -> "NONE"
          value["authority"] == "EXPLICIT_REQUEST" and accepted? -> "EXPLICIT_REQUEST"
          value["authority"] == "STANDING_ORDER" and orders? -> "STANDING_ORDER"
          true -> "NONE"
        end

      value
      |> Map.put("authority", authority)
      |> Map.put(
        "asked_by_message_id",
        if(value["action"] in ["FOREGROUND_REPLY", "NEW_WORK"], do: value["asked_by"])
      )
      |> Map.put(
        "asked_by_state",
        if(is_binary(value["asked_by"]), do: if(accepted?, do: "accepted", else: "degraded"))
      )
      |> Map.put(
        "reason",
        if(authority != value["authority"] and value["action"] == "NEW_WORK",
          do:
            "The proposed authorization source was not present in the current ambient observation.",
          else: value["reason"]
        )
      )
    else
      _ -> invalid
    end
  end

  defp nullable_ids([]), do: %{"type" => "null"}
  defp nullable_ids(ids), do: %{"type" => ["string", "null"], "enum" => ids ++ [nil]}
  defp platform("lark"), do: "Lark"
  defp platform("feishu"), do: "Feishu"
  defp platform("slack"), do: "Slack"
  defp platform("email"), do: "Email"
  defp platform(_), do: "messaging platform"

  defp transcript(rows, zone, now) do
    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, index} ->
      if is_map(row) do
        text = row["text"]
        time = row["sent_at"]
        parsed = Ankole.Attrs.parse_datetime(time)

        if is_binary(text) and text != "" do
          [
            %{
              key:
                if(is_binary(row["conversation_id"]) and is_binary(row["provider_message_id"]),
                  do: row["conversation_id"] <> ":" <> row["provider_message_id"],
                  else: row["id"] || "message:#{index}"
                ),
              id: row["message_id"] || row["id"],
              role: if(row["role"] == "agent", do: "agent", else: "human"),
              index: index,
              order:
                if(parsed,
                  do: DateTime.to_unix(parsed, :microsecond),
                  else: 9_007_199_254_740_991
                ),
              speaker:
                if(is_binary(row["speaker"]) and row["speaker"] != "",
                  do: row["speaker"],
                  else: "Unknown"
                ),
              text: text,
              time:
                if(parsed,
                  do: transcript_time(parsed, zone, now),
                  else: if(is_binary(time) and time != "", do: time, else: "time unknown")
                )
            }
          ]
        else
          []
        end
      else
        []
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.key)
    |> Enum.sort_by(&{&1.order, &1.index})
  end

  defp transcript_time(at, zone, now) do
    same_date? =
      String.slice(local_time(at, zone, false), 0, 10) ==
        String.slice(local_time(now, zone, false), 0, 10)

    local_time(at, zone, same_date?)
  end

  defp local_time(at, zone, short?) do
    zone = if zone == "UTC", do: "Etc/UTC", else: zone

    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> Calendar.strftime(local, if(short?, do: "%H:%M", else: "%Y-%m-%d %H:%M"))
      _ -> DateTime.to_iso8601(at)
    end
  end

  defp active_work_section(jobs, complete?) do
    rows =
      Enum.map(jobs, fn job ->
        "- Job #{job["job_id"]} [#{job["status"]}] #{job["title"]}" <>
          if(job["task_excerpt"] in [nil, ""],
            do: "",
            else: "\n  Task: #{String.trim(job["task_excerpt"])}"
          )
      end)

    cond do
      jobs == [] and complete? ->
        "Active Work Candidates: none."

      jobs == [] ->
        "Active Work Candidates: the list is incomplete, so HANDOFF is unavailable."

      true ->
        Enum.join(
          [
            "Active Work Candidates:",
            if(complete?,
              do: "The list is complete; HANDOFF is allowed only to one exact Job ID below.",
              else:
                "The list is incomplete; HANDOFF is unavailable. Use these rows only to avoid duplicating known work."
            )
            | rows
          ],
          "\n"
        )
    end
  end

  defp observation_transcript(data, zone, now) do
    delta = transcript(data["observed_messages"] || [], zone, now)

    if delta == [],
      do:
        {transcript(
           data["unreplied_messages"] || [],
           zone,
           now
         ), []},
      else: {delta, transcript(data["backdrop_messages"] || [], zone, now)}
  end

  defp transcript_line(row, delta?),
    do:
      "- " <>
        if(delta? and row.role == "human" and is_binary(row.id), do: "[id:#{row.id}] ", else: "") <>
        "#{row.time} [#{row.role}] #{row.speaker}: #{row.text}"

  def resolve(%Signal{} = event, now) do
    Repo.transact(fn repo ->
      :ok = Queue.lock_session_in_tx(repo, event.agent_uid, event.session_id)

      case Ankole.Signals.lock_signal_in_tx(repo, event.id) do
        %Signal{completed_at: %DateTime{}} = completed_event ->
          {:ok, %{status: :already_completed, signal: completed_event}}

        %Signal{input_state: "open"} = locked_event ->
          cond do
            repo.get(AmbientJudgment, locked_event.id) ->
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
    end)
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
    Signal
    |> where([pending], pending.agent_uid == ^event.agent_uid)
    |> where([pending], pending.session_id == ^event.session_id)
    |> where(
      [pending],
      pending.type == "im.message.may_intervene" and pending.producer == :kernel
    )
    |> where([pending], pending.input_state == "open")
    |> where([pending], is_nil(pending.completed_at))
    |> where([pending], is_nil(pending.last_attempt_at))
    |> same_signal_channel(event.conversation_id)
    |> order_by([pending], asc: pending.queue_sequence)
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  defp same_signal_channel(query, conversation_id) when is_binary(conversation_id) do
    where(query, [pending], pending.conversation_id == ^conversation_id)
  end

  defp same_signal_channel(query, nil) do
    where(query, [pending], is_nil(pending.conversation_id))
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
            "status" => job.status,
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
      Binding
      |> where([binding], binding.agent_uid == ^event.agent_uid)
      |> where([binding], binding.name == ^event.reply_binding_name)
      |> lock("FOR SHARE")
      |> repo.one()

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
