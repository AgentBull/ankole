defmodule Ankole.E2E.PodContentEvidence do
  @moduledoc "Public, durable evidence captured before real Pod story fixtures are removed."

  import Ecto.Query

  alias Ankole.AIGateway.Schemas.Message, as: GatewayMessage
  alias Ankole.BackgroundAgentJobs.Schemas.{Job, Turn, TurnItem}
  alias Ankole.Conversations
  alias Ankole.Pod.{Page, PageContent}
  alias Ankole.Repo
  alias Ankole.Signals.Signal

  def observe_record_writes! do
    if Mix.env() != :test, do: raise("record observation requires the test database")

    name = "pod_record_observer_" <> String.replace(Ecto.UUID.generate(), "-", "")
    observer = %{name: name, tenant_id: Repo.tenant_id!()}

    {:ok, :ok} =
      Repo.transact(fn repo ->
        repo.query!("CREATE SCHEMA #{name}")

        # No foreign key can remove this evidence when a record is deleted.
        # The trigger and the business write commit or roll back together.
        repo.query!("""
        CREATE TABLE #{name}.writes (
          sequence bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
          operation text NOT NULL,
          table_id uuid NOT NULL,
          record_id uuid NOT NULL,
          data jsonb NOT NULL,
          actor text NOT NULL
        )
        """)

        repo.query!("""
        CREATE FUNCTION #{name}.capture() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          INSERT INTO #{name}.writes (operation, table_id, record_id, data, actor)
          VALUES (TG_OP, NEW.table_id, NEW.id, NEW.data, NEW.updated_by);
          RETURN NEW;
        END;
        $$
        """)

        repo.query!("""
        CREATE TRIGGER #{name} AFTER INSERT OR UPDATE ON db_records
        FOR EACH ROW WHEN (NEW.tenant_id = '#{observer.tenant_id}'::uuid)
        EXECUTE FUNCTION #{name}.capture()
        """)

        {:ok, :ok}
      end)

    ExUnit.Callbacks.on_exit(fn -> stop_record_observer!(observer) end)
    observer
  end

  def record_writes(observer, table_id, phase \\ :observed)
      when phase in [:observed, :before_human, :after_human] do
    writes = record_write_rows(observer, "WHERE table_id = $1::text::uuid", [table_id])
    write_private_trace!("record-writes-#{phase}-#{table_id}", %{writes: writes}, [])
    writes
  end

  def stop_record_observer!(observer) do
    {:ok, writes} =
      Repo.transact(fn repo ->
        repo.query!("SET LOCAL lock_timeout = '5s'")
        repo.query!("DROP TRIGGER IF EXISTS #{observer.name} ON db_records")

        %{rows: [[present]]} =
          repo.query!("SELECT to_regclass($1) IS NOT NULL", [observer.name <> ".writes"])

        writes = if present, do: record_write_rows(observer, "", []), else: nil
        repo.query!("DROP SCHEMA IF EXISTS #{observer.name} CASCADE")
        {:ok, writes}
      end)

    if writes do
      write_private_trace!("record-writes-#{observer.name}", %{writes: writes}, [])
    end

    :ok
  end

  defp record_write_rows(observer, where, params) do
    result =
      Repo.query!(
        """
        SELECT sequence, operation, table_id::text, record_id::text, data, actor
        FROM #{observer.name}.writes #{where} ORDER BY sequence
        """,
        params
      )

    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  def delivery_evidence(ctx, completion, detail, delivered?) do
    jobs =
      Repo.all(
        from job in Job,
          where: job.agent_uid == ^ctx.agent.uid,
          order_by: job.id,
          select:
            map(job, [
              :id,
              :title,
              :task,
              :status,
              :attempts,
              :runtime_thread_id,
              :continued_from_job_id,
              :source_signal_id,
              :source_tool_call_id,
              :result,
              :error
            ])
      )
      |> Enum.map(fn job ->
        job
        |> Map.update!(:result, fn result ->
          result
          |> Map.take(~w(stop_reason codex_turn_status))
          |> Map.put("output_text", text_metadata(result["output_text"]))
        end)
        |> Map.update!(:error, &Map.take(&1 || %{}, ~w(code type retryable)))
      end)

    ids = Enum.map(jobs, & &1.id)

    turns =
      Repo.all(
        from turn in Turn,
          where: turn.job_id in ^ids,
          order_by: [turn.started_at, turn.id],
          select:
            map(turn, [
              :id,
              :job_id,
              :attempt,
              :runtime_thread_id,
              :runtime_turn_id,
              :status,
              :started_at,
              :completed_at
            ])
      )

    items =
      Repo.all(
        from item in TurnItem,
          join: turn in Turn,
          on: item.turn_id == turn.id and item.tenant_id == turn.tenant_id,
          where: turn.job_id in ^ids,
          where: fragment("? ->> 'type'", item.item) in ["agentMessage", "commandExecution"],
          order_by: [turn.started_at, turn.id, item.position],
          select: %{
            job_id: turn.job_id,
            turn_id: turn.id,
            position: item.position,
            item: item.item
          }
      )

    messages =
      for row <- items,
          row.item["type"] == "agentMessage" do
        item = Ankole.AIGateway.OpaqueContent.reveal(row.item)
        phase = item["phase"]

        row
        |> Map.delete(:item)
        |> Map.merge(%{
          phase: phase,
          text: text_metadata(item["text"])
        })
      end

    commands =
      for row <- items,
          row.item["type"] == "commandExecution",
          is_binary(row.item["command"]),
          String.contains?(row.item["command"], "ankole-pod") do
        row
        |> Map.delete(:item)
        |> Map.merge(Map.take(row.item, ["command", "exitCode", "status"]))
      end

    responses =
      Repo.all(
        from message in GatewayMessage,
          where: message.subject_uid == ^ctx.agent.uid and message.type == "message",
          order_by: [desc: message.inserted_at, desc: message.id],
          select: %{
            id: message.id,
            conversation_id: message.conversation_id,
            status: message.status,
            content: message.content,
            inserted_at: message.inserted_at,
            updated_at: message.updated_at,
            upstream_progress: fragment("? -> 'upstream_progress'", message.metadata),
            model: fragment("? ->> 'provider_model'", message.metadata),
            stop_reason: fragment("? ->> 'stop_reason'", message.metadata),
            response_status: fragment("? -> 'response' ->> 'status'", message.metadata),
            incomplete_reason:
              fragment("? -> 'incomplete_details' ->> 'reason'", message.metadata),
            error_code: fragment("? -> 'error' ->> 'code'", message.metadata),
            error_type: fragment("? -> 'error' ->> 'type'", message.metadata)
          }
      )

    save_private_trace!(ctx.agent.uid, completion.id, responses, ids)

    evidence = %{
      jobs: jobs,
      turns: turns,
      response_finishes: Enum.map(responses, &Map.delete(&1, :content)),
      main_tool_calls:
        for response <- responses,
            item <- response.content,
            item["type"] in ["function_call", "custom_tool_call"] do
          item
          |> Map.take(~w(type name call_id))
          |> Map.put(:message_id, response.id)
        end,
      public_agent_messages: messages,
      last_cli_commands: Enum.take(commands, -12),
      last_command_statuses:
        items
        |> Enum.filter(&(&1.item["type"] == "commandExecution"))
        |> Enum.take(-5)
        |> Enum.map(fn row ->
          row
          |> Map.delete(:item)
          |> Map.merge(Map.take(row.item, ~w(status startedAt completedAt exitCode)))
        end),
      completion: %{
        id: completion.id,
        type: completion.type,
        completed_at: completion.completed_at,
        data: Map.take(completion.data, ~w(job_id title status))
      },
      chat:
        Enum.map(detail.messages, fn message ->
          message
          |> Map.take([:id, :seq, :author_uid, :links, :signal_id])
          |> Map.put(:author_type, to_string(message.author_type))
        end)
    }

    save_evidence!("delivery-#{completion.id}", evidence)

    if delivered? do
      summary = %{
        jobs:
          Enum.map(jobs, fn job ->
            job
            |> Map.take([:id, :status, :attempts, :runtime_thread_id])
            |> Map.put(
              :result,
              job.result
            )
          end),
        message_phases: Enum.map(messages, &Map.delete(&1, :text)),
        response_finishes: Enum.take(evidence.response_finishes, 5),
        completion: evidence.completion,
        chat_links: evidence.chat
      }

      IO.puts("Pod delivery public summary: " <> Ankole.JSON.encode!(Ankole.JSON.plain(summary)))
    else
      IO.puts(
        "Pod delivery public evidence: " <> Ankole.JSON.encode!(Ankole.JSON.plain(evidence))
      )
    end
  end

  defp text_metadata(text) when is_binary(text) do
    %{bytes: byte_size(text), sha256: Base.encode16(:crypto.hash(:sha256, text), case: :lower)}
  end

  defp text_metadata(_), do: nil

  defp save_private_trace!(agent_uid, completion_id, responses, job_ids) do
    # Diagnostic capture must not replace the product result with its own error.
    Ankole.Observability.Trace.safe(:ok, fn ->
      case Ankole.AgentWorkers.WorkerEnv.sensitive_values(agent_uid) do
        {:ok, secrets} ->
          secrets = Enum.sort_by(secrets, &byte_size/1, :desc)

          trace =
            Enum.flat_map(responses, fn response ->
              items =
                response.content
                |> Enum.filter(
                  &(&1["type"] in ~w(function_call custom_tool_call function_call_output custom_tool_call_output))
                )
                |> Enum.map(fn item ->
                  item
                  |> Ankole.AIGateway.OpaqueContent.reveal()
                  |> Map.take(~w(type name call_id arguments input output status))
                  |> decode_trace_json("arguments")
                  |> decode_trace_json("output")
                end)

              if items == [],
                do: [],
                else: [response |> Map.delete(:content) |> Map.put(:items, items)]
            end)

          write_private_trace!("delivery-#{completion_id}", trace, secrets)

          jobs =
            Ankole.Observability.Trace.safe(%{unavailable: "job_trace_capture_failed"}, fn ->
              private_job_trace(job_ids)
            end)

          write_private_trace!("jobs-#{completion_id}", jobs, secrets)

        {:error, _reason} ->
          for name <- ["delivery-#{completion_id}", "jobs-#{completion_id}"] do
            write_private_trace!(name, %{omitted: "secret_filter_unavailable"}, [])
          end
      end
    end)
  end

  defp private_job_trace(job_ids) do
    jobs =
      Repo.all(
        from job in Job,
          where: job.id in ^job_ids,
          order_by: job.id,
          select:
            map(job, [
              :id,
              :status,
              :attempts,
              :runtime_thread_id,
              :workspace_owner_job_id,
              :workspace_template_id,
              :continued_from_job_id,
              :source_signal_id,
              :source_tool_call_id
            ])
      )

    turns =
      Repo.all(
        from turn in Turn,
          where: turn.job_id in ^job_ids,
          order_by: [turn.started_at, turn.id],
          select:
            map(turn, [
              :id,
              :job_id,
              :attempt,
              :runtime_thread_id,
              :runtime_turn_id,
              :kind,
              :status,
              :revision,
              :trajectory,
              :error,
              :started_at,
              :completed_at
            ])
      )
      |> Enum.map(fn turn ->
        turn
        |> Map.put(:content_flags, turn.trajectory["metadata"] || %{})
        |> Map.delete(:trajectory)
      end)

    # Include every stored semantic item and every owned thread. The public
    # projection intentionally omits most tools and all raw message text.
    items =
      Repo.all(
        from item in TurnItem,
          join: turn in Turn,
          on: item.turn_id == turn.id and item.tenant_id == turn.tenant_id,
          where: turn.job_id in ^job_ids,
          order_by: [turn.started_at, turn.id, item.position],
          select: %{
            job_id: turn.job_id,
            turn_id: turn.id,
            runtime_thread_id: turn.runtime_thread_id,
            runtime_turn_id: turn.runtime_turn_id,
            position: item.position,
            revision: item.revision,
            item_key: item.item_key,
            inserted_at: item.inserted_at,
            item: item.item
          }
      )
      |> Enum.map(
        &Map.update!(&1, :item, fn item -> Ankole.AIGateway.OpaqueContent.reveal(item) end)
      )

    %{
      jobs: jobs,
      turns: turns,
      items: items,
      workspace_files: %{
        status: "unavailable",
        reason: "not_collected_by_durable_turn_snapshot",
        paths: ["research-state.md", "report/report.md"]
      }
    }
  end

  defp write_private_trace!(name, value, secrets) do
    trace =
      value
      |> Ankole.JSON.plain()
      |> Ankole.Observability.Trace.sanitize()
      |> redact_trace(secrets)

    directory = Path.join(evidence_directory(), "private")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    path = Path.join(directory, name <> ".json")
    File.touch!(path)
    File.chmod!(path, 0o600)
    File.write!(path, Ankole.JSON.encode!(trace))
  end

  defp decode_trace_json(item, key) do
    case item[key] do
      value when is_binary(value) ->
        case Ankole.JSON.decode(value) do
          {:ok, decoded} when is_map(decoded) or is_list(decoded) -> Map.put(item, key, decoded)
          _other -> item
        end

      _other ->
        item
    end
  end

  defp redact_trace(value, secrets) when is_binary(value),
    do: Ankole.Conversations.Delivery.SecretFilter.redact_text(value, secrets)

  defp redact_trace(value, secrets) when is_list(value),
    do: Enum.map(value, &redact_trace(&1, secrets))

  defp redact_trace(value, secrets) when is_map(value) do
    value
    |> Map.drop(["env", "environment"])
    |> Map.new(fn {key, item} -> {key, redact_trace(item, secrets)} end)
  end

  defp redact_trace(value, _secrets), do: value

  # Capture before committed fixtures disappear. A ready Worker or a succeeded Job
  # alone cannot distinguish a stuck main turn from a delivered saved artifact.
  def request(ctx, input) do
    {activity, driver} =
      Ankole.Sessions.Activity.current(%{
        agent_uid: ctx.agent.uid,
        session_id: input.session_id
      })

    driver_state =
      if is_pid(driver) do
        case Process.info(driver, [:status, :current_function, :message_queue_len]) do
          nil -> nil
          info -> info |> Map.new() |> Map.update(:current_function, nil, &inspect/1)
        end
      end

    signals =
      Repo.all(
        from signal in Signal,
          where: signal.agent_uid == ^ctx.agent.uid and signal.session_id == ^input.session_id,
          order_by: signal.queue_sequence,
          select:
            map(signal, [
              :id,
              :type,
              :message_id,
              :queue_sequence,
              :input_state,
              :completed_at,
              :final_response_id,
              :turn_outcome,
              :attempt_count,
              :last_attempt_at,
              :dead_letter_at,
              :dead_letter_reason
            ])
      )

    pages =
      Repo.all(
        from page in Page,
          left_join: content in PageContent,
          on: content.page_id == page.id and content.tenant_id == page.tenant_id,
          order_by: page.id,
          select: %{
            id: page.id,
            type: page.type,
            title: page.title,
            parent_id: page.parent_id,
            revision: page.revision,
            saved_from_message_id: page.saved_from_message_id,
            created_by: page.created_by,
            updated_at: page.updated_at,
            content_updated_by: content.updated_by,
            plain_text: content.plain_text
          }
      )
      |> Enum.map(fn page ->
        page
        |> Map.update!(:created_by, &Ankole.Pod.Serialization.json_value/1)
        |> Map.update!(:content_updated_by, &Ankole.Pod.Serialization.json_value/1)
        |> Map.update!(:plain_text, &text_metadata/1)
      end)

    evidence = %{
      input_id: input.id,
      activity: activity,
      driver: driver_state,
      signals: signals,
      pages: pages
    }

    save_evidence!("request-#{input.id}", evidence)

    IO.puts(
      "Pod request terminal state: " <>
        Ankole.JSON.encode!(Ankole.JSON.plain(evidence))
    )

    with {:ok, detail} <- Conversations.get(input.human_uid, input.conversation_id),
         %Signal{} = latest <-
           Repo.one(
             from signal in Signal,
               where:
                 signal.agent_uid == ^ctx.agent.uid and signal.session_id == ^input.session_id,
               order_by: [desc: signal.queue_sequence],
               limit: 1
           ) do
      delivery_evidence(ctx, latest, detail, false)
    end
  end

  defp save_evidence!(name, evidence) do
    directory = evidence_directory()
    File.mkdir_p!(directory)

    File.write!(
      Path.join(directory, name <> ".json"),
      Ankole.JSON.encode!(Ankole.JSON.plain(evidence))
    )
  end

  defp evidence_directory,
    do:
      System.get_env("POD_REAL_LLM_ARTIFACT_DIR") ||
        Path.join(System.tmp_dir!(), "ankole-pod-real-llm-artifacts")
end
