defmodule Ankole.Sessions.ReceiptsTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Sessions.Receipts
  alias Ankole.Sessions.Tools

  alias Ankole.Sessions.Workspaces
  alias Ankole.Principals.Principal

  setup do
    %{principal: agent} = agent_fixture()
    session_id = "receipts:#{System.unique_integer([:positive])}"
    {:ok, workspace} = Workspaces.ensure(agent.uid, session_id)
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

    assert {:ok, receipt} = Receipts.execute(run, "resp_1", "call_1", operation)
    Repo.update!(change(Repo.get!(Principal, run.agent_uid), display_name: "Operator edit"))
    assert {:ok, ^receipt} = Receipts.execute(run, "resp_1", "call_1", operation)
    assert Repo.get!(Principal, run.agent_uid).display_name == "Operator edit"
  end

  test "a failed tool transaction commits neither domain writes nor a receipt (G3)", %{run: run} do
    original = Repo.get!(Principal, run.agent_uid).display_name

    operation = fn repo ->
      repo.update!(change(repo.get!(Principal, run.agent_uid), display_name: "Rolled back"))
      {:error, :failed}
    end

    assert {:error, :failed} = Receipts.execute(run, "resp_1", "call_1", operation)
    assert Repo.get!(Principal, run.agent_uid).display_name == original
    assert {:error, :receipt_not_found} = Receipts.fetch("resp_1", "call_1")
  end

  test "a stale driver cannot write after the receipt moved to tape (G6)", %{
    run: run,
    workspace: workspace
  } do
    assert {:ok, _} =
             Receipts.execute(run, "resp_1", "call_1", fn _ ->
               {:ok, Tools.result(%{"ok" => true}), []}
             end)

    Repo.transact(fn repo ->
      Receipts.delete_round_in_tx(repo, run, "resp_1")
      repo.update!(change(workspace, epoch: 2))
      {:ok, :done}
    end)

    assert {:error, :stale_driver} =
             Receipts.execute(run, "resp_1", "call_1", fn _ -> flunk("stale tool executed") end)
  end

  test "equal call ids in different Responses hold independent results (G3)", %{run: run} do
    assert {:ok, first} =
             Receipts.execute(run, "resp_1", "call_1", fn _ ->
               {:ok, Tools.result(%{"value" => 1}), []}
             end)

    assert {:ok, second} =
             Receipts.execute(run, "resp_2", "call_1", fn _ ->
               {:ok, Tools.result(%{"value" => 2}), []}
             end)

    assert first.result["details"] == %{"value" => 1}
    assert second.result["details"] == %{"value" => 2}
  end

  test "post-commit actions run only for the transaction that inserts a receipt (G3)", %{run: run} do
    owner = self()

    operation = fn _ ->
      {:ok, Tools.result(%{"ok" => true}), [fn -> send(owner, :committed) end]}
    end

    assert {:ok, _} = Receipts.execute(run, "resp_1", "call_1", operation)
    assert_receive :committed
    assert {:ok, _} = Receipts.execute(run, "resp_1", "call_1", operation)
    refute_receive :committed
  end

  test "a failed notification preserves the committed result and does not repeat the write (G3)",
       %{run: run} do
    operation = fn repo ->
      repo.update!(change(repo.get!(Principal, run.agent_uid), display_name: "Committed"))
      {:ok, Tools.result(%{"ok" => true}), [fn -> raise "notification unavailable" end]}
    end

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert {:ok, receipt} =
                      Receipts.execute(run, "resp_notification", "call_1", operation)

             refute receipt.result["is_error"]

             assert {:ok, ^receipt} =
                      Receipts.execute(run, "resp_notification", "call_1", fn _ ->
                        flunk("write repeated")
                      end)
           end) =~ "notification unavailable"

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

    run =
      Map.merge(run, %{
        model_response: %{id: "response-attachment"},
        event: Repo.get!(Ankole.Signals.Signal, run.signal_id),
        tools: [tool]
      })

    call = %{
      "name" => "reply_attachment",
      "call_id" => "attachment-1",
      "arguments" => ~s({"drive_path":"reports/q3.txt"})
    }

    assert {:ok, selected, args} = Tools.prepare(run, call)
    assert selected.executor == Ankole.Sessions.Presentation
    result = Tools.execute(run, call, selected, args)
    refute result.is_error
    assert [attachment] = result.details["attachments"]
    assert attachment["path"] == "reports/q3.txt"
    assert attachment["blob_ref"] == Base.encode16(original.sha256, case: :lower)

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
end
