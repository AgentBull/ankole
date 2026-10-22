defmodule Ankole.Sessions.ReceiptsTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Sessions.Receipts
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.Turn
  alias Ankole.Sessions.Tools

  alias Ankole.Principals.Principal

  setup do
    %{principal: agent} = agent_fixture()
    session_id = "receipts:#{System.unique_integer([:positive])}"
    {:ok, workspace} = Ankole.SessionsCase.ensure_workspace(agent.uid, session_id)
    workspace = Repo.update!(change(workspace, epoch: 1))

    {:ok, event} =
      Repo.transact(fn repo ->
        Ankole.Signals.accept_in_tx(repo, %{
          producer: :kernel,
          target: %{agent_uid: agent.uid, session_id: session_id},
          source: "test:runtime",
          reply_route: %{binding_name: "control-plane:test"},
          sender: agent.uid,
          id: Ecto.UUID.generate(),
          data: %{},
          type: "test.work",
          available_at: DateTime.utc_now(),
          authorization: Ankole.Principals.WorkAccess.service()
        })
      end)

    {:ok,
     run: %{
       agent_uid: agent.uid,
       session_id: session_id,
       epoch: workspace.epoch,
       signal_id: event.id
     },
     workspace: workspace}
  end

  test "recovery returns the committed result and preserves a later operator edit (G3)", %{
    run: run
  } do
    operation = fn repo ->
      repo.update!(change(repo.get!(Principal, run.agent_uid), display_name: "Tool write"))
      {:ok, Tools.result(%{"ok" => true}), []}
    end

    assert {:ok, receipt} =
             Receipts.execute(run, "resp_1", "call_1", prepare_operation(operation))

    Repo.update!(change(Repo.get!(Principal, run.agent_uid), display_name: "Operator edit"))

    assert {:ok, recovered} =
             Receipts.execute(run, "resp_1", "call_1", prepare_operation(operation))

    assert_persisted_equal(recovered, receipt)

    assert Repo.get!(Principal, run.agent_uid).display_name == "Operator edit"
  end

  test "a failed tool transaction commits neither domain writes nor a receipt (G3)", %{run: run} do
    original = Repo.get!(Principal, run.agent_uid).display_name

    operation = fn repo ->
      repo.update!(change(repo.get!(Principal, run.agent_uid), display_name: "Rolled back"))
      {:error, :failed}
    end

    assert {:error, :failed} =
             Receipts.execute(run, "resp_1", "call_1", prepare_operation(operation))

    assert Repo.get!(Principal, run.agent_uid).display_name == original
    assert {:error, :receipt_not_found} = Receipts.fetch("resp_1", "call_1")
  end

  test "failed preparation rolls back provisional facts before a commit function exists", %{
    run: run
  } do
    original = Repo.get!(Principal, run.agent_uid).display_name

    prepare = fn repo ->
      repo.update!(change(repo.get!(Principal, run.agent_uid), display_name: "Provisional"))
      {:error, :preparation_failed}
    end

    assert {:error, :preparation_failed} =
             Receipts.execute(run, "resp_prepare", "call_1", prepare)

    assert Repo.get!(Principal, run.agent_uid).display_name == original
    assert {:error, :receipt_not_found} = Receipts.fetch("resp_prepare", "call_1")
  end

  test "invalid durable JSON rolls back the tool effect and its receipt", %{run: run} do
    principal = Repo.get!(Principal, run.agent_uid)

    for value <- [:runtime_atom, {:runtime_tuple, 1}, self()] do
      operation = fn _repo ->
        {:ok, _} = Ankole.Ash.update(principal, :profile_in_tx, %{display_name: "Uncommitted"})

        {:ok, %Ankole.Sessions.ToolResult{details: %{"invalid" => value}, output: "Uncommitted"},
         []}
      end

      assert {:error, %Ash.Error.Invalid{} = error} =
               Receipts.execute(run, "resp_invalid_json", "call_1", prepare_operation(operation))

      assert [%{path: "result"}] = Ankole.Ash.validation_details(error)
      assert Repo.get!(Principal, run.agent_uid).display_name == principal.display_name
      assert {:error, :receipt_not_found} = Receipts.fetch("resp_invalid_json", "call_1")
    end
  end

  test "PostgreSQL rejects non-object round journals" do
    for field <- [:pages, :results] do
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            "INSERT INTO session_round_states (tenant_id, message_id, #{field}) " <>
              "VALUES ($1::text::uuid, $2::text::uuid, '[]'::jsonb)",
            [Repo.tenant_id!(), Ankole.Ecto.UUIDv7.autogenerate()],
            mode: :savepoint
          )
        end

      assert error.postgres.constraint == "session_round_states_#{field}_object"
    end
  end

  test "receipts reject a surrounding transaction before preparing any effect", %{run: run} do
    assert_raise Ash.Error.Framework, ~r/must run at the top level/, fn ->
      Repo.transact(fn _ ->
        Receipts.execute(run, "resp_outer", "call_1", fn _ ->
          flunk("nested preparation executed")
        end)
      end)
    end

    assert {:error, :receipt_not_found} = Receipts.fetch("resp_outer", "call_1")
  end

  test "a stale driver cannot write after the receipt moved to tape (G6)", %{
    run: run,
    workspace: workspace
  } do
    assert {:ok, _} =
             Receipts.execute(
               run,
               "resp_1",
               "call_1",
               prepare_operation(fn _ ->
                 {:ok, Tools.result(%{"ok" => true}), []}
               end)
             )

    Repo.transact(fn repo ->
      Receipts.delete_round_in_tx(repo, run, "resp_1")
      repo.update!(change(workspace, epoch: 2))
      {:ok, :done}
    end)

    assert {:error, :stale_driver} =
             Receipts.execute(
               run,
               "resp_1",
               "call_1",
               prepare_operation(fn _ -> flunk("stale tool executed") end)
             )
  end

  for reason <- [:stale_driver, :run_closed] do
    @reason reason
    test "the tool boundary preserves #{@reason} as a Driver control result", %{
      run: run,
      workspace: workspace
    } do
      case @reason do
        :stale_driver ->
          Repo.update!(change(workspace, epoch: workspace.epoch + 1))

        :run_closed ->
          event = Repo.get!(Ankole.Signals.Signal, run.signal_id)

          Repo.update!(
            change(event, status: :completed, completed_at: DateTime.utc_now(:microsecond))
          )
      end

      run =
        struct!(
          Run,
          Map.merge(run, %{
            event: Repo.get!(Ankole.Signals.Signal, run.signal_id),
            model_response: %{id: "resp_fenced_tool"}
          })
        )

      tool =
        Tools.Workflow.declarations()
        |> Enum.find(&(&1["name"] == "workflow"))
        |> Ankole.Sessions.Tool.new(Tools.Workflow)

      call = %{"name" => "workflow", "call_id" => "fenced-call"}
      args = %{"title" => "Fenced workflow", "script" => "return 42;"}

      assert {:error, @reason} == Tools.execute(run, call, tool, args)
      assert {:error, :receipt_not_found} = Receipts.fetch("resp_fenced_tool", "fenced-call")

      refute Repo.exists?(
               from r in Ankole.Workflow.Schemas.Run, where: r.agent_uid == ^run.agent_uid
             )
    end
  end

  test "equal call ids in different Responses hold independent results (G3)", %{run: run} do
    assert {:ok, first} =
             Receipts.execute(
               run,
               "resp_1",
               "call_1",
               prepare_operation(fn _ ->
                 {:ok, Tools.result(%{"value" => 1}), []}
               end)
             )

    assert {:ok, second} =
             Receipts.execute(
               run,
               "resp_2",
               "call_1",
               prepare_operation(fn _ ->
                 {:ok, Tools.result(%{"value" => 2}), []}
               end)
             )

    assert first.result["details"] == %{"value" => 1}
    assert second.result["details"] == %{"value" => 2}
  end

  test "post-commit actions run only for the transaction that inserts a receipt (G3)", %{run: run} do
    owner = self()

    operation = fn _ ->
      {:ok, Tools.result(%{"ok" => true}), [fn -> send(owner, :committed) end]}
    end

    assert {:ok, _} = Receipts.execute(run, "resp_1", "call_1", prepare_operation(operation))
    assert_receive :committed
    assert {:ok, _} = Receipts.execute(run, "resp_1", "call_1", prepare_operation(operation))
    refute_receive :committed
  end

  test "a failed notification preserves the committed result and does not repeat the write (G3)",
       %{run: run} do
    secret = "private-notification-token-/srv/private/receipt"

    operation = fn repo ->
      repo.update!(change(repo.get!(Principal, run.agent_uid), display_name: "Committed"))
      {:ok, Tools.result(%{"ok" => true}), [fn -> raise secret end]}
    end

    log =
      ExUnit.CaptureLog.capture_log([format: "$metadata $message\n", metadata: :all], fn ->
        assert {:ok, receipt} =
                 Receipts.execute(
                   run,
                   "resp_notification",
                   "call_1",
                   prepare_operation(operation)
                 )

        refute receipt.result["is_error"]

        assert {:ok, recovered} =
                 Receipts.execute(
                   run,
                   "resp_notification",
                   "call_1",
                   prepare_operation(fn _ ->
                     flunk("write repeated")
                   end)
                 )

        assert_persisted_equal(recovered, receipt)
      end)

    assert log =~ "sessions.receipt.notification_failed"
    assert log =~ "RuntimeError"
    assert log =~ "receipts_test.exs"
    refute log =~ secret

    assert Repo.get!(Principal, run.agent_uid).display_name == "Committed"
  end

  test "a drive attachment records its source and rejects a changed source before delivery (G1, G3)",
       %{run: run} do
    Ankole.FilesFixtures.drive_file_fixture(run.agent_uid, "reports/q3.txt", "original report")
    {:ok, original} = Ankole.Files.fetch(run.agent_uid, "reports/q3.txt")

    tool =
      Ankole.Sessions.Presentation.declarations()
      |> hd()
      |> Ankole.Sessions.Tool.new(Ankole.Sessions.Presentation)

    call = %{
      "name" => "reply_attachment",
      "call_id" => "attachment-1",
      "arguments" => ~s({"drive_path":"reports/q3.txt"})
    }

    run =
      struct!(
        Run,
        Map.merge(run, %{
          model_response: %{id: "response-attachment"},
          event: Repo.get!(Ankole.Signals.Signal, run.signal_id),
          tools: [tool],
          calls: [call]
        })
      )

    turn = %Turn{key: %{agent_uid: run.agent_uid, session_id: run.session_id}, run: run}
    {turn, _} = Turn.step(%{turn | stage: :boundary}, {:resume, run.epoch, :executing_tools})
    {turn, commands} = Turn.step(turn, :tools)

    assert {:tool, _, %{tool: selected, args: args}} =
             Enum.find(commands, &match?({:tool, _, _}, &1))

    assert {:present, [activity]} = Enum.find(commands, &match?({:present, [_]}, &1))

    assert %{
             "kind" => "tool.activity",
             "payload" => %{
               "operation_id" => "attachment-1",
               "phase" => "running",
               "label_key" => "conversations.delivery.reply.activity.attachment_prepare"
             }
           } = activity

    assert selected.executor == Ankole.Sessions.Presentation
    result = Tools.execute(run, call, selected, args)
    refute result.is_error
    assert [attachment] = result.details["attachments"]
    assert attachment["path"] == "reports/q3.txt"
    assert attachment["blob_ref"] == Base.encode16(original.sha256, case: :lower)

    assert {%{run: completed, pending: empty_pending}, commands} =
             Turn.step(turn, {:completed, {:tool, "attachment-1"}, result})

    assert {:present, [activity]} = Enum.find(commands, &match?({:present, [_]}, &1))

    assert empty_pending == %{}
    assert completed.results["attachment-1"] == result
    assert completed.visible_delivery?
    assert activity["payload"]["phase"] == "completed"

    assert activity["payload"]["label_key"] ==
             "conversations.delivery.reply.activity.attachment_prepare"

    Ankole.FilesFixtures.drive_file_fixture(run.agent_uid, "reports/q3.txt", "operator revision")
    assert Tools.execute(run, call, selected, args) == result

    assert {:error, {:reply_attachment_not_in_drive, "reports/q3.txt"}} =
             Ankole.Conversations.Delivery.Attachment.verify_in_drive(run.agent_uid, [attachment])

    assert {:error, %Ankole.Sessions.ToolResult{failure_kind: "invalid_arguments"}} =
             Tools.prepare(run, Map.put(call, "arguments", ~s({"path":"/workspace/answer.txt"})))

    assert {:error, %Ankole.Sessions.ToolResult{failure_kind: "invalid_arguments"}} =
             Tools.prepare(
               run,
               Map.put(call, "arguments", ~s({"drive_path":"reports/q3.txt","mimeType":""}))
             )
  end

  defp prepare_operation(operation) do
    fn repo -> {:ok, [], fn -> operation.(repo) end} end
  end
end
