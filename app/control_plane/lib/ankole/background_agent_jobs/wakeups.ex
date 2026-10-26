defmodule Ankole.BackgroundAgentJobs.Wakeups do
  @moduledoc false

  alias Ankole.BackgroundAgentJobs.Attrs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.I18n
  alias Ankole.Signals.Signal
  alias Ankole.Text

  @max_event_payload_bytes 16_384
  @artifact_path_limit 32
  @artifact_path_bytes 8_192
  @internal_uuid_pattern ~r/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/i
  @path_handoff_keys [
    {"files_changed", :files_changed},
    {"artifacts", :artifacts},
    {"artifact_roots", :artifact_roots}
  ]
  @truncation_suffix "...[truncated]"

  @background_job_wakeup_notice_keys %{
    "background_agent_job.completed" => "background_agent_job_dead_letter_succeeded",
    "background_agent_job.failed" => "background_agent_job_dead_letter_failed",
    "background_agent_job.input_undeliverable" => "background_agent_job_dead_letter_waiting",
    "background_agent_job.waiting" => "background_agent_job_dead_letter_waiting"
  }

  @doc false
  @spec conclude_transition_in_tx(Job.t(), DateTime.t(), map() | nil) ::
          {:ok, Signal.t() | nil} | {:error, term()}
  # A skill-lesson reflection is a system job: its end must wake no session.
  # A succeeded reflection instead enqueues the apply worker inside this
  # transaction, so lessons land only after the terminal status is durable.
  def conclude_transition_in_tx(
        %Job{metadata: %{"skill_lesson_reflection" => true}} = job,
        _now,
        _steer_outcome
      ) do
    if job.status == :succeeded do
      {:ok, _oban_job} =
        %{"job_id" => job.id}
        |> Ankole.Brain.Jobs.ApplySkillLessons.new()
        |> Oban.insert()
    end

    {:ok, nil}
  end

  def conclude_transition_in_tx(%Job{} = job, %DateTime{} = now, steer_outcome),
    do: append_wakeup_event(job, now, steer_outcome)

  @doc false
  @spec enqueue_input_undeliverable_in_tx(
          Job.t(),
          Signal.t(),
          DateTime.t()
        ) :: {:ok, Signal.t() | nil} | {:error, term()}
  def enqueue_input_undeliverable_in_tx(
        %Job{metadata: %{"skill_lesson_reflection" => true}},
        %Signal{},
        %DateTime{}
      ),
      do: {:ok, nil}

  def enqueue_input_undeliverable_in_tx(
        %Job{} = job,
        %Signal{} = steer_event,
        %DateTime{} = now
      ) do
    event_type = "background_agent_job.input_undeliverable"
    source_event_id = "background_agent_job:#{job.id}:input_undeliverable:#{steer_event.id}"
    reply_route = job.reply_route || %{}

    data =
      Attrs.reject_nil_values(%{
        "job_id" => job.id,
        "title" => job.title,
        "status" => Atom.to_string(job.status),
        "workspace_template_id" => job.workspace_template_id,
        "attempts" => job.attempts,
        "result_summary" =>
          "Follow-up input could not be delivered because the Agent Computer worker remained unavailable.",
        "reply_route" => reply_route,
        "pending_user_input" => get_in(job.metadata || %{}, ["pending_user_input"]),
        "undelivered_signal_id" => steer_event.id
      })

    with true <-
           (is_binary(reply_route["binding_name"]) or
              match?({:ok, _}, Ecto.UUID.cast(reply_route["conversation_id"]))) ||
             {:error, :background_agent_job_reply_route_binding_missing} do
      Ankole.Signals.accept_in_tx(%{
        producer: :kernel,
        source: "control-plane://background-agent-job",
        id: source_event_id,
        type: event_type,
        subject: "background-agent-job:#{job.id}",
        time: now,
        data: data,
        target: %{agent_uid: job.agent_uid, session_id: job.owner_session_id},
        sender: nil,
        authorization: Ankole.Principals.WorkAccess.fields(job),
        reply_route: reply_route
      })
    end
  end

  @doc false
  @spec bound_result_path_handoffs(map()) :: map()
  def bound_result_path_handoffs(%{"result" => result} = attrs) when is_map(result) do
    result =
      Enum.reduce(@path_handoff_keys, result, fn {key, atom_key}, bounded ->
        case Map.fetch(bounded, key) do
          {:ok, value} ->
            bounded
            |> Map.delete(atom_key)
            |> Map.put(key, bounded_path_handoff(value))

          :error ->
            case Map.fetch(bounded, atom_key) do
              {:ok, value} ->
                bounded
                |> Map.delete(atom_key)
                |> Map.put(key, bounded_path_handoff(value))

              :error ->
                bounded
            end
        end
      end)

    Map.put(attrs, "result", result)
  end

  def bound_result_path_handoffs(attrs), do: attrs

  @doc false
  @spec dead_letter_notice_text(Signal.t()) :: String.t() | nil
  def dead_letter_notice_text(%Signal{type: type} = event)
      when is_map_key(@background_job_wakeup_notice_keys, type) do
    data = event.data

    detail =
      [
        text_value(data["result_summary"]),
        artifacts_notice_line(data["artifacts"]),
        successor_notice_line(data["successor_job_id"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    I18n.t(
      "conversations.delivery.reply.#{Map.fetch!(@background_job_wakeup_notice_keys, type)}",
      %{
        "job_id" => data["job_id"] || 0,
        "title" => text_value(data["title"]) || "",
        "detail" => detail
      }
    )
  end

  def dead_letter_notice_text(%Signal{}), do: nil

  defp append_wakeup_event(%Job{} = job, now, steer_outcome) do
    case wakeup_event_type(job.status) do
      nil ->
        {:ok, nil}

      event_type ->
        source_event_id = wakeup_source_event_id(job)
        reply_route = job.reply_route || %{}

        payload = wakeup_payload(job, source_event_id, event_type, now, steer_outcome)

        with true <-
               (is_binary(reply_route["binding_name"]) or
                  match?({:ok, _}, Ecto.UUID.cast(reply_route["conversation_id"]))) ||
                 {:error, :background_agent_job_reply_route_binding_missing} do
          Ankole.Signals.accept_in_tx(%{
            producer: :kernel,
            source: payload["source"],
            id: source_event_id,
            type: event_type,
            subject: payload["subject"],
            time: now,
            data: payload["data"],
            target: %{agent_uid: job.agent_uid, session_id: job.owner_session_id},
            sender: nil,
            authorization: Ankole.Principals.WorkAccess.fields(job),
            reply_route: reply_route
          })
        end
    end
  end

  defp wakeup_event_type(:succeeded), do: "background_agent_job.completed"
  defp wakeup_event_type(:failed), do: "background_agent_job.failed"
  defp wakeup_event_type(:waiting_on_user), do: "background_agent_job.waiting"
  defp wakeup_event_type(_status), do: nil

  defp wakeup_source_event_id(%Job{status: :waiting_on_user} = job) do
    "background_agent_job:#{job.id}:waiting:#{job.attempts}"
  end

  defp wakeup_source_event_id(%Job{} = job) do
    "background_agent_job:#{job.id}:#{job.status}:#{job.attempts}"
  end

  defp wakeup_payload(job, source_event_id, event_type, now, steer_outcome) do
    %{
      "specversion" => "1.0",
      "id" => source_event_id,
      "source" => "control-plane://background-agent-job",
      "subject" => "background-agent-job:#{job.id}",
      "time" => DateTime.to_iso8601(now),
      "type" => event_type,
      "data" =>
        Attrs.reject_nil_values(%{
          "job_id" => job.id,
          "title" => job.title,
          "status" => Atom.to_string(job.status),
          "workspace_template_id" => job.workspace_template_id,
          "attempts" => job.attempts,
          "result_summary" => result_summary(job),
          "artifacts" => Map.get(job.result || %{}, "artifacts"),
          "artifact_roots" => Map.get(job.result || %{}, "artifact_roots"),
          "project_path" => Map.get(job.result || %{}, "project_path"),
          "reply_route" => job.reply_route || %{},
          "pending_user_input" => get_in(job.metadata || %{}, ["pending_user_input"]),
          "successor_job_id" => steer_outcome[:successor_job_id]
        })
    }
  end

  defp result_summary(%Job{status: :succeeded, result: result}) do
    result
    |> map_summary([{"summary", :summary}, {"output_text", :output_text}])
    |> truncate_summary()
  end

  defp result_summary(%Job{status: :failed, error: error}) do
    error
    |> map_summary([
      {"summary", :summary},
      {"reason", :reason},
      {"message", :message},
      {"code", :code}
    ])
    |> remove_internal_uuid_tokens()
    |> truncate_summary()
  end

  defp result_summary(%Job{}), do: nil

  defp bounded_path_handoff(paths) when is_list(paths),
    do: build_path_handoff(paths, nil, false)

  defp bounded_path_handoff(%{} = handoff) do
    build_path_handoff(
      path_handoff_value(handoff, "paths", :paths, []),
      path_handoff_value(handoff, "total_count", :total_count),
      path_handoff_value(handoff, "truncated", :truncated) == true
    )
  end

  defp bounded_path_handoff(_value), do: nil

  defp build_path_handoff(paths, declared_total, declared_truncated) when is_list(paths) do
    observed_count = length(paths)
    paths = Enum.filter(paths, &(is_binary(&1) and &1 != ""))
    invalid_paths = length(paths) != observed_count
    total_count = max(observed_count, valid_total_count(declared_total))

    {selected, _serialized_bytes} =
      Enum.reduce_while(paths, {[], 2}, fn path, {selected, serialized_bytes} ->
        if path in selected do
          {:cont, {selected, serialized_bytes}}
        else
          if length(selected) >= @artifact_path_limit do
            {:halt, {selected, serialized_bytes}}
          else
            added_bytes =
              byte_size(Ankole.JSON.encode!(path)) + if(selected == [], do: 0, else: 1)

            if serialized_bytes + added_bytes <= @artifact_path_bytes do
              {:cont, {[path | selected], serialized_bytes + added_bytes}}
            else
              {:cont, {selected, serialized_bytes}}
            end
          end
        end
      end)

    selected = Enum.reverse(selected)

    %{
      "total_count" => total_count,
      "paths" => selected,
      "truncated" => declared_truncated or invalid_paths or length(selected) < total_count
    }
  end

  defp build_path_handoff(_paths, declared_total, _declared_truncated),
    do: build_path_handoff([], declared_total, true)

  defp valid_total_count(value) when is_integer(value) and value >= 0, do: value
  defp valid_total_count(_value), do: 0

  defp path_handoff_value(handoff, key, atom_key, default \\ nil) do
    case Map.fetch(handoff, key) do
      {:ok, value} -> value
      :error -> Map.get(handoff, atom_key, default)
    end
  end

  defp map_summary(value, preferred_keys) when is_map(value) do
    preferred_keys
    |> Enum.find_value(fn {string_key, atom_key} ->
      case Map.get(value, string_key) || Map.get(value, atom_key) do
        text when is_binary(text) and text != "" -> text
        _value -> nil
      end
    end)
  end

  defp map_summary(_value, _preferred_keys), do: nil

  defp remove_internal_uuid_tokens(nil), do: nil

  defp remove_internal_uuid_tokens(text) when is_binary(text),
    do: Regex.replace(@internal_uuid_pattern, text, "[internal-id]")

  defp truncate_summary(nil), do: nil

  defp truncate_summary(summary) when is_binary(summary) do
    if byte_size(summary) <= @max_event_payload_bytes do
      summary
    else
      Text.truncate_utf8(summary, @max_event_payload_bytes, @truncation_suffix)
    end
  end

  defp text_value(value) when is_binary(value) and value != "", do: value
  defp text_value(_value), do: nil

  defp artifacts_notice_line(%{"paths" => paths}) when is_list(paths) and paths != [] do
    I18n.t("conversations.delivery.reply.background_agent_job_dead_letter_artifacts", %{
      "paths" => Enum.join(paths, ", ")
    })
  end

  defp artifacts_notice_line(_artifacts), do: nil

  defp successor_notice_line(successor_job_id) when is_integer(successor_job_id) do
    I18n.t("conversations.delivery.reply.background_agent_job_dead_letter_successor", %{
      "successor_job_id" => successor_job_id
    })
  end

  defp successor_notice_line(_successor), do: nil
end
