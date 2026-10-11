defmodule Ankole.Conversations.ChatDriveTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  import Ankole.FilesFixtures, only: [drive_file_fixture: 3]

  alias Ankole.Conversations.{Admission, Context, Prompt, ToolCatalog, Tools}
  alias Ankole.Files
  alias Ankole.SignalsGateway.ActorRuntime.TurnEnvelope

  setup {Ankole.SignalsGateway.ActorRuntimeCase, :use_mock_signal_provider_plugin}

  test "the same received bytes and filename have separate channel paths and provenance" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    {:ok, stored} = Ingress.store_attachment(%{"name" => "private.txt"}, "private content")

    for {channel_id, directory} <- [
          {"mock:dm:alice", "chats/mock:dm:alice"},
          {"mock:dm:bob", "chats/mock:dm:bob"},
          {".", "chats/%2E"},
          {"..", "chats/%2E%2E"}
        ] do
      input = input!(agent.uid, channel_id, attachments: [stored])
      path = "#{directory}/#{stored["path"]}"
      assert [%{"path" => ^path}] = get_in(input.payload, ["data", "entry", "attachments"])

      assert {:ok, %{signal_channel_id: ^channel_id, source_entry_id: entry_id},
              "private content"} =
               Files.read(agent.uid, path)

      assert entry_id == input.source_entry_id

      run = prepare_run(input)
      messages = Prompt.user(run, input)
      assert Ankole.JSON.encode!(messages) =~ path
    end

    assert {:error, :not_found} = Files.fetch(agent.uid, stored["path"])
  end

  test "reply_attachment retains the original drive path and refuses a foreign conversation file" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    input = input!(agent.uid, "mock:dm:alice")
    run = prepare_run(input)

    assert Prompt.system(Map.put(run, :available_tool_names, Enum.map(run.tools, & &1.name))) =~
             "This is a private conversation with the other person."

    own = "chats/mock:dm:alice/report.txt"
    foreign = "chats/mock:dm:bob/report.txt"
    drive_file_fixture(agent.uid, own, "Alice report")
    drive_file_fixture(agent.uid, foreign, "Bob report")
    drive_file_fixture(agent.uid, "shared/report.txt", "Shared report")

    # The Agent can read its whole drive. The channel restriction applies at delivery.
    assert {:ok, _file, "Bob report"} = Files.read(agent.uid, foreign)
    {run, call} = response_call(run, "reply_attachment", %{"drive_path" => foreign})
    assert {:ok, tool, args} = Tools.prepare(run, call)
    assert tool.executor == Ankole.Conversations.Presentation
    refute Tools.needs_worker?(run, call)
    assert %{is_error: true, output: error} = Tools.execute(run, call, tool, args)
    assert error =~ "file_channel_mismatch"

    assert {:error, :receipt_not_found} =
             Ankole.Conversations.Receipts.fetch("resp_#{run.model_response.id}", call["call_id"])

    for path <- [own, "shared/report.txt"] do
      {run, call} = response_call(run, "reply_attachment", %{"drive_path" => path})
      {:ok, tool, args} = Tools.prepare(run, call)

      assert %{is_error: false, details: %{"attachments" => [%{"path" => ^path}]}} =
               Tools.execute(run, call, tool, args)
    end

    assert {:ok, %{files: []}} = Files.list(agent.uid, "sent")
    assert Repo.aggregate(OutboxEntry, :count) == 0

    assert {:error, %{failure_kind: "invalid_arguments"}} =
             Tools.prepare(run, Map.put(call, "arguments", ~s({"path":"report.txt"})))
  end

  test "send_message checks the actual destination and rolls back all posts on rejection" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    input = input!(agent.uid, "mock:dm:alice")
    target = input!(agent.uid, "mock:dm:bob")
    run = prepare_run(input)
    path = "chats/mock:dm:alice/report.txt"
    drive_file_fixture(agent.uid, path, "Alice report")

    {run, call} =
      response_call(run, "send_message", %{
        "destination" => %{"binding" => "bot", "channel_id" => target.signal_channel_id},
        "text" => "Here is the report.",
        "attachments" => [path]
      })

    {:ok, tool, args} = Tools.prepare(run, call)
    assert %{is_error: true, output: error} = Tools.execute(run, call, tool, args)
    assert error =~ "file_channel_mismatch"
    assert Repo.aggregate(OutboxEntry, :count) == 0

    for delivery_path <- [path, "shared/report.txt"] do
      drive_file_fixture(agent.uid, delivery_path, "Report")
      destination = if delivery_path == path, do: input, else: target

      {run, call} =
        response_call(run, "send_message", %{
          "destination" => %{"binding" => "bot", "channel_id" => destination.signal_channel_id},
          "text" => "Report.",
          "attachments" => [delivery_path]
        })

      {:ok, tool, args} = Tools.prepare(run, call)
      assert {:await, _wait} = Tools.execute(run, call, tool, args)
    end

    assert Repo.aggregate(OutboxEntry, :count) == 4
  end

  test "the Outbox rejects channel-prefix confusion, encoded channel mismatch, and missing destinations" do
    %{principal: agent} = agent_fixture()
    {:ok, stored} = Files.store("report")
    path = Files.chat_path("mock:dm:alice/bob", "report.txt")
    assert path == "chats/mock:dm:alice%2Fbob/report.txt"

    attrs = %{
      agent_uid: agent.uid,
      binding_name: "bot",
      operation: :post,
      outbound_key: "attachment",
      payload: %{
        "attachments" => [%{"path" => path, "blob_ref" => stored.sha256, "name" => "report.txt"}]
      }
    }

    for channel_id <- [nil, "", "mock:dm:alice", "mock:dm:alice/bob-extra", "mock:dm:alice%2Fbob"] do
      assert {:error, {:file_channel_mismatch, ^path}} =
               SignalsGateway.commit_outbox(Map.put(attrs, :signal_channel_id, channel_id))
    end

    assert Repo.aggregate(OutboxEntry, :count) == 0

    assert {:ok, row} =
             SignalsGateway.commit_outbox(Map.put(attrs, :signal_channel_id, "mock:dm:alice/bob"))

    assert row.signal_channel_id == "mock:dm:alice/bob"
  end

  test "a Background Job keeps its source conversation drive directory" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    input = input!(agent.uid, "mock:dm:alice")
    run = prepare_run(input)

    {:ok, %{job: job}} =
      Repo.transact(fn _repo ->
        Ankole.BackgroundAgentJobs.create_with_dispatch(%{
          "source_actor_event_id" => input.id,
          "agent_uid" => agent.uid,
          "owner_session_id" => input.session_id,
          "source_tool_call_id" => "job-drive",
          "title" => "Prepare report",
          "task" => "Prepare and save the report.",
          "reply_route" => %{
            "binding_name" => "bot",
            "signal_channel_id" => input.signal_channel_id
          }
        })
      end)

    assert job.metadata["owner_conversation_id"] == run.conversation.id
    session_id = Ankole.BackgroundAgentJobs.job_session_id(job.id)
    assert {:ok, context} = Context.resolve(agent.uid, session_id)

    assert TurnEnvelope.agent_context(context).conversation.drive_directory ==
             "chats/mock:dm:alice"
  end

  defp input!(agent_uid, channel_id, opts \\ []) do
    {:ok, %{actor_event: input}} =
      emit_entry(
        agent_uid,
        "bot",
        group_entry(%{
          signal_channel_id: channel_id,
          channel: %{kind: :im_dm, reply_mode: :channel},
          explicit: true,
          attachments: Keyword.get(opts, :attachments, [])
        }),
        now: @base_time
      )

    input
  end

  defp prepare_run(input) do
    {:ok, run} = Admission.admit(input, input)
    {:ok, context} = Context.resolve(run.agent_uid, run.session_id)
    {tools, hosted_tools} = ToolCatalog.for_run(%{run | context: context})
    %{run | context: context, tools: tools, hosted_tools: hosted_tools}
  end

  defp response_call(run, name, args) do
    call = %{
      "type" => "function_call",
      "name" => name,
      "call_id" => "call-#{System.unique_integer([:positive])}",
      "arguments" => Ankole.JSON.encode!(args)
    }

    {:ok, response} =
      start_response_run(%{subject_uid: run.agent_uid, conversation_id: run.conversation.id})

    {:ok, response} = StatefulResponses.commit_complete(response, [call])
    {%{run | model_response: response}, call}
  end
end
