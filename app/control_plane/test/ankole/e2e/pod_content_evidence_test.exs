defmodule Ankole.E2E.PodContentEvidenceTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import ExUnit.CaptureIO

  alias Ankole.E2E.PodContentEvidence
  alias Ankole.BackgroundAgentJobs.Schemas.{Job, Turn, TurnItem}
  alias Ankole.Pod.{Database, Documents, Pages}
  alias Ankole.Signals.Signal

  setup do
    directory = Path.join(System.tmp_dir!(), "pod-evidence-#{Ecto.UUID.generate()}")
    previous = System.get_env("POD_REAL_LLM_ARTIFACT_DIR")
    System.put_env("POD_REAL_LLM_ARTIFACT_DIR", directory)

    on_exit(fn ->
      if previous,
        do: System.put_env("POD_REAL_LLM_ARTIFACT_DIR", previous),
        else: System.delete_env("POD_REAL_LLM_ARTIFACT_DIR")

      File.rm_rf!(directory)
    end)

    {:ok, directory: directory}
  end

  test "request evidence preserves page attribution without leaking raw content", %{
    directory: directory
  } do
    owner = human_fixture().principal
    agent = agent_fixture().principal
    {:ok, page} = Pages.create(owner.uid, %{title: "Evidence attribution"})
    body = "Business text must stay private"
    {:ok, _} = Documents.write(owner.uid, page.id, page.revision, "<page><p>#{body}</p></page>")

    input = %Signal{
      id: Ecto.UUID.generate(),
      agent_uid: agent.uid,
      human_uid: owner.uid,
      session_id: "conversation:#{Ecto.UUID.generate()}",
      conversation_id: Ecto.UUID.generate()
    }

    output = capture_io(fn -> PodContentEvidence.request(%{agent: agent}, input) end)
    refute output =~ body

    encoded =
      directory
      |> Path.join("request-#{input.id}.json")
      |> File.read!()

    refute encoded =~ body
    evidence = Ankole.JSON.decode!(encoded)

    saved = Enum.find(evidence["pages"], &(&1["id"] == page.id))
    reference = "ankole:#{owner.tenant_id}:principal/#{owner.uid}"
    assert saved["created_by"] == reference
    assert saved["content_updated_by"] == reference
    assert saved["plain_text"]["bytes"] > 0
    assert byte_size(saved["plain_text"]["sha256"]) == 64
    assert is_binary(saved["updated_at"])
    refute Map.has_key?(saved, "content")
    refute Map.has_key?(saved, "__struct__")
  end

  @tag sandbox: false
  test "record observation retains committed writes after deletion and cleans up its database objects",
       %{directory: directory} do
    Ankole.E2E.Harness.cleanup_committed_fixtures_on_exit!()
    owner = human_fixture().principal
    {:ok, page} = Pages.create(owner.uid, %{type: "database"})
    {:ok, table} = Database.create_table(owner.uid, page.id, %{name: "Sales"})
    primary = Enum.find(Database.fields(table.id), & &1.is_primary)
    {:ok, other} = Database.create_table(owner.uid, page.id, %{name: "Other sales"})
    other_primary = Enum.find(Database.fields(other.id), & &1.is_primary)
    observer = PodContentEvidence.observe_record_writes!()

    assert {:ok, %{records: [cedar]}} =
             Database.write_records(owner.uid, table.id, %{
               creates: [%{data: %{primary.id => "Cedar"}}]
             })

    assert {:ok, _} =
             Database.write_records(owner.uid, table.id, %{
               deletes: [%{id: cedar.id, expected_versions: cedar.versions}]
             })

    assert {:ok, %{records: []}} = Database.query(owner.uid, table.id, %{})

    tenant_id = Repo.tenant_id!()

    writes =
      Repo.checkout(fn ->
        %{rows: [[writer_connection]]} = Repo.query!("SELECT pg_backend_pid()")

        Task.async(fn ->
          Repo.with_tenant(tenant_id, fn ->
            %{rows: [[reader_connection]]} = Repo.query!("SELECT pg_backend_pid()")
            refute reader_connection == writer_connection
            PodContentEvidence.record_writes(observer, table.id)
          end)
        end)
        |> Task.await()
      end)

    assert [%{"operation" => "INSERT", "record_id" => id, "data" => data}] = writes
    assert id == cedar.id
    assert data[primary.id] == "Cedar"
    assert hd(writes)["actor"] == "ankole:#{owner.tenant_id}:principal/#{owner.uid}"

    assert {:ok, _} =
             Database.write_records(owner.uid, other.id, %{
               creates: [%{data: %{other_primary.id => "Cedar"}}]
             })

    assert PodContentEvidence.record_writes(observer, table.id) == writes
    assert [%{"table_id" => other_id}] = PodContentEvidence.record_writes(observer, other.id)
    assert other_id == other.id

    assert {:ok, %{records: [pending]}} =
             Database.write_records(owner.uid, table.id, %{
               creates: [%{data: %{primary.id => "Pending"}}]
             })

    assert {:ok, %{records: [renamed]}} =
             Database.write_records(owner.uid, table.id, %{
               updates: [
                 %{
                   id: pending.id,
                   data: %{primary.id => "Cedar"},
                   expected_versions: pending.versions
                 }
               ]
             })

    assert {:ok, _} =
             Database.write_records(owner.uid, table.id, %{
               deletes: [%{id: renamed.id, expected_versions: renamed.versions}]
             })

    assert {:ok, %{records: []}} = Database.query(owner.uid, table.id, %{})
    writes = PodContentEvidence.record_writes(observer, table.id)
    assert Enum.map(writes, & &1["operation"]) == ["INSERT", "INSERT", "UPDATE"]
    assert List.last(writes)["data"][primary.id] == "Cedar"

    assert Enum.map(Enum.filter(writes, &(&1["data"][primary.id] == "Cedar")), & &1["record_id"]) ==
             [cedar.id, renamed.id]

    # The test owns the transaction, so it runs the write body and rolls back.
    assert {:error, :rolled_back} =
             Repo.transact(fn ->
               assert {:ok, _} =
                        Database.write_records_in_tx(owner.uid, table.id, %{
                          creates: [%{data: %{primary.id => "Cedar"}}]
                        })

               {:error, :rolled_back}
             end)

    assert PodContentEvidence.record_writes(observer, table.id) == writes
    assert :ok = PodContentEvidence.stop_record_observer!(observer)
    assert :ok = PodContentEvidence.stop_record_observer!(observer)

    assert %{rows: [[nil]]} = Repo.query!("SELECT to_regnamespace($1)::text", [observer.name])

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM pg_trigger WHERE tgname = $1", [observer.name])

    path = Path.join([directory, "private", "record-writes-#{observer.name}.json"])
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert %{"writes" => saved} = path |> File.read!() |> Ankole.JSON.decode!()
    assert length(saved) == 4
  end

  test "private tool traces decode commands and retain results without exposing secrets", %{
    directory: directory
  } do
    agent = agent_fixture().principal
    secret = "private-trace-secret-value"

    assert {:ok, _} =
             Ankole.AgentWorkers.WorkerEnv.console_put_for_agent(agent.uid, "TRACE_SECRET", %{
               "value" => secret,
               "secret" => true
             })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "trace-test")

    command = "grep -n Total /workspace/sales/src/App.tsx"
    opaque = "ankole-aigateway-opaque-v1:" <> Base.url_encode64(command, padding: false)
    body = "private tool result body"

    insert_message = fn content, previous ->
      {:ok, message} =
        Repo.transact(fn ->
          Ankole.Ash.create(Ankole.AIGateway.Schemas.Message, :journal, %{
            subject_uid: agent.uid,
            conversation_id: conversation.id,
            previous_message_id: previous,
            content: content
          })
        end)

      message
    end

    call =
      insert_message.(
        [
          %{
            "type" => "function_call",
            "name" => "command",
            "call_id" => "trace-call",
            "arguments" =>
              Ankole.JSON.encode!(%{
                "command" => opaque,
                "api_key" => secret,
                "env" => %{"TRACE_SECRET" => secret}
              })
          }
        ],
        nil
      )

    insert_message.(
      [
        %{
          "type" => "function_call_output",
          "call_id" => "trace-call",
          "output" => body <> " " <> secret
        }
      ],
      call.id
    )

    completion = %Signal{
      id: Ecto.UUID.generate(),
      type: "background_agent_job.completed",
      data: %{}
    }

    output =
      capture_io(fn ->
        PodContentEvidence.delivery_evidence(%{agent: agent}, completion, %{messages: []}, false)
      end)

    refute output =~ body
    refute output =~ command
    refute output =~ secret

    public = File.read!(Path.join(directory, "delivery-#{completion.id}.json"))
    refute public =~ body
    refute public =~ command
    refute public =~ secret

    path = Path.join([directory, "private", "delivery-#{completion.id}.json"])
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    trace = File.read!(path)
    refute trace =~ secret
    refute trace =~ "ankole-aigateway-opaque-v1:"
    items = trace |> Ankole.JSON.decode!() |> Enum.flat_map(& &1["items"])
    saved_call = Enum.find(items, &(&1["type"] == "function_call"))
    saved_result = Enum.find(items, &(&1["type"] == "function_call_output"))
    assert saved_call["arguments"]["command"] == command
    refute Map.has_key?(saved_call["arguments"], "api_key")
    refute Map.has_key?(saved_call["arguments"], "env")
    assert saved_result["call_id"] == "trace-call"
    assert saved_result["output"] == body <> " [REDACTED]"
  end

  test "private Job evidence retains verifier calls and results from all owned threads", %{
    directory: directory
  } do
    agent = agent_fixture().principal
    secret = "job-evidence-private-secret-value"

    assert {:ok, _} =
             Ankole.AgentWorkers.WorkerEnv.console_put_for_agent(agent.uid, "TRACE_SECRET", %{
               "value" => secret,
               "secret" => true
             })

    %{rows: [[job_id]]} =
      Repo.query!("SELECT nextval(pg_get_serial_sequence('background_agent_jobs', 'id'))")

    now = DateTime.utc_now(:microsecond)

    assert {:ok, job} =
             Repo.transact(fn _ ->
               with {:ok, job} <-
                      Ankole.Ash.create(Job, :create_job, %{
                        id: job_id,
                        agent_uid: agent.uid,
                        owner_session_id: "job-evidence",
                        source_tool_call_id: "job-evidence-#{job_id}",
                        workspace_owner_job_id: job_id,
                        runtime_thread_id: "lead-thread",
                        title: "Review the report",
                        task: "Check the report against the evidence.",
                        result: %{},
                        metadata: %{},
                        error: %{}
                      }) do
                 Ankole.Ash.update(job, :external_complete, %{completed_at: now})
               end
             end)

    lead =
      insert_job_turn!(job, "lead-thread", [
        %{
          "type" => "collabAgentToolCall",
          "id" => "spawn-verifier",
          "tool" => "spawnAgent",
          "agentThreadId" => "verifier-thread",
          "status" => "completed"
        }
      ])

    brief = "SUBTASK BRIEF\nIndependently check the report's conclusion."
    result = "Independent verifier checked the threshold and conclusion."
    command = "python3 verify_conclusion.py"
    opaque = "ankole-aigateway-opaque-v1:" <> Base.url_encode64(command, padding: false)

    child =
      insert_job_turn!(job, "verifier-thread", [
        %{
          "type" => "userMessage",
          "id" => "verifier-brief",
          "content" => [%{"type" => "text", "text" => brief}]
        },
        %{
          "type" => "dynamicToolCall",
          "id" => "verifier-call",
          "tool" => "check_claim",
          "arguments" => %{"subject" => "report", "env" => %{"TRACE_SECRET" => secret}},
          "status" => "completed",
          "success" => true,
          "contentItems" => [%{"type" => "text", "text" => result <> " " <> secret}]
        },
        %{
          "type" => "commandExecution",
          "id" => "verifier-command",
          "command" => opaque,
          "status" => "completed",
          "exitCode" => 0,
          "aggregatedOutput" => result
        }
      ])

    completion = %Signal{
      id: Ecto.UUID.generate(),
      type: "background_agent_job.completed",
      data: %{}
    }

    output =
      capture_io(fn ->
        PodContentEvidence.delivery_evidence(%{agent: agent}, completion, %{messages: []}, false)
      end)

    public = File.read!(Path.join(directory, "delivery-#{completion.id}.json"))

    for value <- [brief, result, command, secret] do
      refute output =~ value
      refute public =~ value
    end

    path = Path.join([directory, "private", "jobs-#{completion.id}.json"])
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
    encoded = File.read!(path)
    refute encoded =~ secret
    refute encoded =~ "ankole-aigateway-opaque-v1:"
    trace = Ankole.JSON.decode!(encoded)
    assert Enum.map(trace["jobs"], & &1["id"]) == [job.id]
    assert MapSet.new(Enum.map(trace["turns"], & &1["id"])) == MapSet.new([lead.id, child.id])
    assert Enum.all?(trace["items"], &(&1["job_id"] == job.id))

    assert Enum.find(trace["items"], &(&1["item"]["id"] == "spawn-verifier"))["runtime_thread_id"] ==
             "lead-thread"

    assert Enum.find(trace["items"], &(&1["item"]["id"] == "verifier-brief"))["item"]["content"] ==
             [%{"type" => "text", "text" => brief}]

    call = Enum.find(trace["items"], &(&1["item"]["id"] == "verifier-call"))
    assert call["runtime_thread_id"] == "verifier-thread"
    assert call["turn_id"] == child.id
    assert call["position"] == 1
    refute Map.has_key?(call["item"]["arguments"], "env")

    assert call["item"]["contentItems"] == [
             %{"type" => "text", "text" => result <> " [REDACTED]"}
           ]

    saved_command = Enum.find(trace["items"], &(&1["item"]["id"] == "verifier-command"))
    assert saved_command["item"]["command"] == command
    assert saved_command["item"]["aggregatedOutput"] == result
    assert saved_command["item"]["exitCode"] == 0
    assert trace["workspace_files"]["status"] == "unavailable"
    assert trace["workspace_files"]["reason"] == "not_collected_by_durable_turn_snapshot"
  end

  defp insert_job_turn!(job, thread, items) do
    now = DateTime.utc_now(:microsecond)

    turn =
      case Repo.transact(fn _ ->
             Ankole.Ash.create(Turn, :record, %{
               job_id: job.id,
               attempt: 1,
               runtime_thread_id: thread,
               runtime_turn_id: "turn-#{thread}",
               status: "completed",
               revision: 1,
               trajectory: %{"format" => "ankole_chatml", "version" => 1},
               started_at: now,
               completed_at: now
             })
           end) do
        {:ok, record} -> record
        {:error, error} -> raise Ash.Error.to_error_class(error)
      end

    items
    |> Enum.with_index()
    |> Enum.each(fn {item, position} ->
      case Repo.transact(fn _ ->
             Ankole.Ash.create(TurnItem, :append, %{
               turn_id: turn.id,
               position: position,
               revision: 1,
               item_key: item["id"],
               item: item
             })
           end) do
        {:ok, record} -> record
        {:error, error} -> raise Ash.Error.to_error_class(error)
      end
    end)

    turn
  end
end
