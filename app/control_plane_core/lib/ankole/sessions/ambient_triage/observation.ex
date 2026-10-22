defmodule Ankole.Sessions.AmbientTriage.Observation do
  @moduledoc "Read-only input for the ambient decision model."

  alias Ankole.Sessions.ToolArguments

  @enforce_keys [:agent_uid, :event, :context, :model_ref, :request_context]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}

  def render(%__MODULE__{} = observation, now \\ DateTime.utc_now(:microsecond)) do
    data = observation.event.data
    zone = observation.context.conversation.timezone || "UTC"
    current = local_time(now, zone, false)
    {delta, backdrop} = observation_transcript(data, zone, now)

    orders = Ankole.Sessions.Prompt.Input.standing_orders(observation.event) || ""
    candidates = observation.request_context["ambient_work_candidates"] || %{}
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

    origin = observation.context.conversation.origin_channel || %{}

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
end
