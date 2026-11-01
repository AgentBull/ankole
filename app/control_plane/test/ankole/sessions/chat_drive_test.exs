defmodule Ankole.Sessions.ChatDriveTest do
  alias Ankole.AIGateway.ResponseCommit
  use Ankole.SessionsCase

  import Ankole.FilesFixtures, only: [drive_file_fixture: 3]

  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Context
  alias Ankole.Sessions.Prompt
  alias Ankole.Sessions.ToolCatalog
  alias Ankole.Sessions.Tools
  alias Ankole.Files
  alias Ankole.Conversations.Attachments
  alias Ankole.Sessions.TurnEnvelope

  setup {Ankole.SessionsCase, :use_mock_signal_provider_plugin}

  test "the same received object has separate shared conversation nodes" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    {:ok, stored} = Attachments.store_attachment(%{"name" => "private.txt"}, "private content")

    nodes =
      for provider_id <- ["mock:dm:alice", "mock:dm:bob", ".", ".."] do
        input = input!(agent.uid, provider_id, attachments: [stored])
        assert [attachment] = get_in(input.data, ["entry", "attachments"])
        assert attachment["object_id"] == stored["object_id"]
        assert {:ok, conversation_id} = Files.node_conversation_id(attachment["node_id"])
        assert conversation_id == input.conversation_id
        assert {:ok, _} = Files.authorize_node(agent.uid, attachment["node_id"], "node_view")
        run = prepare_run(input)
        assert Ankole.JSON.encode!(Prompt.user(run, input)) =~ "ankole-pod chat attachment get"
        attachment["node_id"]
      end

    assert length(Enum.uniq(nodes)) == 4
    assert {:ok, "private content"} = Files.read_object(stored["object_id"])
  end

  test "reply_attachment freezes an authorized node and refuses a foreign conversation root" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    input = input!(agent.uid, "mock:dm:alice")
    other = input!(agent.uid, "mock:dm:bob")
    run = prepare_run(input)
    own = conversation_file!(input.conversation_id, "report.txt", "Alice report")
    foreign = conversation_file!(other.conversation_id, "report.txt", "Bob report")
    private = drive_file_fixture(agent.uid, "shared/report.txt", "Shared report")

    {run, call} = response_call(run, "reply_attachment", %{"node_id" => foreign.id})
    assert {:ok, tool, args} = Tools.prepare(run, call)
    assert %{is_error: true, output: error} = Tools.execute(run, call, tool, args)
    assert error =~ "attachment_conversation_mismatch"

    for file <- [own, private] do
      {run, call} = response_call(run, "reply_attachment", %{"node_id" => file.id})
      {:ok, tool, args} = Tools.prepare(run, call)

      assert %{is_error: false, details: %{"attachments" => [attachment]}} =
               Tools.execute(run, call, tool, args)

      assert attachment["node_id"] == file.id
      assert attachment["object_id"] == file.object_id
    end

    assert Repo.aggregate(Intent, :count) == 0
  end

  test "send_message checks each node's actual root and rolls back all posts on rejection" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    input = input!(agent.uid, "mock:dm:alice")
    target = input!(agent.uid, "mock:dm:bob")
    run = prepare_run(input)
    file = conversation_file!(input.conversation_id, "report.txt", "Alice report")

    {run, call} =
      response_call(run, "send_message", %{
        "destination" => %{"binding" => "bot", "conversation_id" => target.conversation_id},
        "text" => "Here is the report.",
        "attachments" => [file.id]
      })

    {:ok, tool, args} = Tools.prepare(run, call)
    assert %{is_error: true, output: error} = Tools.execute(run, call, tool, args)
    assert error =~ "attachment_conversation_mismatch"
    assert Repo.aggregate(Intent, :count) == 0
    private = drive_file_fixture(agent.uid, "shared/report.txt", "Report")

    for {file, destination} <- [{file, input}, {private, target}] do
      {run, call} =
        response_call(run, "send_message", %{
          "destination" => %{"binding" => "bot", "conversation_id" => destination.conversation_id},
          "text" => "Report.",
          "attachments" => [file.id]
        })

      {:ok, tool, args} = Tools.prepare(run, call)
      assert {:await, _wait} = Tools.execute(run, call, tool, args)
    end

    assert Repo.aggregate(Intent, :count) == 4
  end

  test "a display path cannot disguise a conversation attachment as a private file" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    source = input!(agent.uid, "mock:dm:alice/bob")
    other = input!(agent.uid, "mock:dm:alice")
    file = conversation_file!(source.conversation_id, "report.txt", "report")
    {:ok, attachment} = Ankole.Conversations.Delivery.Attachment.from_node(agent.uid, file.id)

    attrs = %{
      agent_uid: agent.uid,
      binding_name: "bot",
      operation: :post,
      outbound_key: "attachment",
      payload: %{"attachments" => [Map.put(attachment, "path", "shared/report.txt")]}
    }

    for id <- [nil, other.conversation_id] do
      assert {:error, :attachment_conversation_mismatch} =
               Ankole.SignalsFixtures.commit_delivery(Map.put(attrs, :conversation_id, id))
    end

    assert {:ok, _} =
             Ankole.SignalsFixtures.commit_delivery(
               Map.put(attrs, :conversation_id, source.conversation_id)
             )
  end

  defp conversation_file!(id, name, bytes) do
    {:ok, stored} = Files.store(bytes)
    {:ok, file} = Repo.transact(fn -> Files.create_conversation_file_in_tx(id, name, stored) end)
    file
  end

  test "a Background Job keeps its conversation context without a private path alias" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    input = input!(agent.uid, "mock:dm:alice")
    run = prepare_run(input)

    {:ok, %{job: job}} =
      Ankole.BackgroundAgentJobs.create_with_dispatch(%{
        "source_signal_id" => input.id,
        "agent_uid" => agent.uid,
        "owner_session_id" => input.session_id,
        "source_tool_call_id" => "job-drive",
        "title" => "Prepare report",
        "task" => "Prepare and save the report.",
        "reply_route" => %{
          "binding_name" => "bot",
          "conversation_id" => input.conversation_id
        }
      })

    assert job.metadata["owner_conversation_id"] == run.conversation.id
    session_id = Ankole.BackgroundAgentJobs.job_session_id(job.id)
    assert {:ok, context} = Context.resolve(agent.uid, session_id)

    assert TurnEnvelope.agent_context(context).conversation.timezone ==
             context.conversation.timezone

    assert TurnEnvelope.agent_context(context).conversation.pod_instructions == ""
    assert TurnEnvelope.agent_context(context).conversation.page_id == ""
  end

  defp input!(agent_uid, channel_id, opts \\ []) do
    {:ok, %{signal: input}} =
      emit_entry(
        agent_uid,
        "bot",
        group_entry(%{
          provider_conversation_id: channel_id,
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
    {:ok, _} =
      Ankole.AuthZ.upsert_permission_grant(%{
        principal_uid: run.event.human_uid,
        resource_pattern: "agent:#{run.agent_uid}:tool:#{name}",
        action: "invoke"
      })

    call = %{
      "type" => "function_call",
      "name" => name,
      "call_id" => "call-#{System.unique_integer([:positive])}",
      "arguments" => Ankole.JSON.encode!(args)
    }

    {:ok, response} =
      start_response_run(%{subject_uid: run.agent_uid, conversation_id: run.conversation.id})

    {:ok, response} = ResponseCommit.commit_complete(response, [call])
    {%{run | model_response: response}, call}
  end
end
