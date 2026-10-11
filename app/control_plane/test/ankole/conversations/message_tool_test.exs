defmodule Ankole.Conversations.MessageToolTest do
  use Ankole.SignalsGateway.ActorRuntimeCase
  import Ankole.FilesFixtures, only: [drive_file_fixture: 3]
  alias Ankole.Conversations.{Admission, Context, ToolCatalog, Tools}

  setup {Ankole.SignalsGateway.ActorRuntimeCase, :use_mock_signal_provider_plugin}

  test "send_message posts its text and each attachment, and reports sent after all of them" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")

    {:ok, %{actor_event: input}} =
      emit_entry(agent.uid, "bot", group_entry(%{text: "Share the report", explicit: true}),
        now: @base_time
      )

    drive_file_fixture(agent.uid, "reports/weekly.pdf", "%PDF weekly")
    {:ok, run} = Admission.admit(input, input)
    {:ok, context} = Context.resolve(run.agent_uid, run.session_id)
    {tools, _hosted} = ToolCatalog.for_run(%{run | context: context})

    call = %{
      "type" => "function_call",
      "name" => "send_message",
      "call_id" => "send-1",
      "arguments" =>
        Ankole.JSON.encode!(%{
          "destination" => %{"binding" => "bot", "channel_id" => input.signal_channel_id},
          "text" => "Here is the weekly report.",
          "attachments" => ["reports/weekly.pdf"]
        })
    }

    {:ok, response} =
      start_response_run(%{subject_uid: run.agent_uid, conversation_id: run.conversation.id})

    {:ok, response} = StatefulResponses.commit_complete(response, [call])
    run = %{run | context: context, tools: tools, model_response: response}

    assert {:ok, tool, args} = Tools.prepare(run, call)
    assert {:await, wait} = Tools.execute(run, call, tool, args)

    rows =
      Repo.all(
        from row in OutboxEntry,
          where: row.agent_uid == ^agent.uid and like(row.outbound_key, "tool:%"),
          order_by: row.outbound_key
      )

    assert [text, attachment] = rows
    assert text.payload == %{"text" => "Here is the weekly report."}
    refute Map.has_key?(attachment.payload, "text")
    assert [%{"name" => "weekly.pdf"}] = attachment.payload["attachments"]

    # The call is sent only when every post succeeded.
    succeed!(text)
    assert :pending = Tools.Message.observe(run, wait, false, false)
    succeed!(attachment)

    assert {:ready, %{details: %{"status" => "sent"}}, []} =
             Tools.Message.observe(run, wait, false, false)
  end

  defp succeed!(row) do
    row
    |> Ecto.Changeset.change(
      status: :succeeded,
      created_source_entry_id: "posted-#{row.outbound_key}"
    )
    |> Repo.update!()
  end
end
