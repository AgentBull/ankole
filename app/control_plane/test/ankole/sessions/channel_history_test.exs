defmodule Ankole.Sessions.ChannelHistoryTest do
  use Ankole.SessionsCase
  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Context, as: SessionContext
  alias Ankole.Sessions.ToolCatalog
  alias Ankole.Sessions.Tools
  alias Ankole.Conversations.Context

  setup {Ankole.SessionsCase, :use_mock_signal_provider_plugin}

  test "read_channel_history pages the current channel oldest first and filters by text" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    {:ok, %{signal: input}} =
      emit_entry(agent.uid, "bot", group_entry(%{text: "Summarize this week", explicit: true}),
        now: @base_time
      )

    channel_id = input.conversation_id

    for day <- 1..3 do
      at = DateTime.add(@base_time, -day * 86_400)

      insert_message!(input.conversation_id, %{
        provider_message_id: "history-#{day}",
        text: "Decision #{day}: ship release #{day}",
        author: %{"display_name" => "Lin"},
        provider_time: at
      })
    end

    {:ok, run} = Admission.admit(input, input)
    {:ok, context} = SessionContext.resolve(run.agent_uid, run.session_id)
    {tools, _hosted} = ToolCatalog.for_run(%{run | context: context})
    run = %{run | context: context, tools: tools, pages: %{}, todo: [], web_cache: %{}}

    {run, first} = read(run, %{"query" => "DECISION", "until" => DateTime.to_iso8601(@base_time)})

    assert [%{"text" => "Decision 1: ship release 1", "speaker" => "Lin"} | _] =
             first.details["messages"]

    assert length(first.details["messages"]) == 3
    assert first.details["next_page"] == nil

    # A one-message page continues from its cursor.
    page = Context.history_page(channel_id, query: "decision")
    assert length(page.messages) == 3

    {_run, since} =
      read(run, %{"since" => DateTime.to_iso8601(DateTime.add(@base_time, -2 * 86_400))})

    assert Enum.map(since.details["messages"], & &1["text"]) == [
             "Summarize this week",
             "Decision 1: ship release 1",
             "Decision 2: ship release 2"
           ]
  end

  test "the history pages at its row limit and resumes after the cursor" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    {:ok, %{signal: input}} =
      emit_entry(agent.uid, "bot", group_entry(%{text: "start", explicit: true}), now: @base_time)

    for index <- 1..205 do
      at = DateTime.add(@base_time, index)

      insert_message!(input.conversation_id, %{
        provider_message_id: "page-#{index}",
        text: "message #{index}",
        author: %{},
        provider_time: at
      })
    end

    first = Context.history_page(input.conversation_id, query: "message")
    assert length(first.messages) == 200
    assert is_binary(first.next_cursor)

    rest =
      Context.history_page(input.conversation_id,
        query: "message",
        cursor: first.next_cursor
      )

    assert Enum.map(rest.messages, & &1["text"]) == Enum.map(201..205, &"message #{&1}")
    assert rest.next_cursor == nil
  end

  defp insert_message!(id, attrs) do
    {:ok, result} =
      Repo.transact(fn ->
        Ankole.Conversations.External.observe_in_tx(id, attrs, attrs.provider_time)
      end)

    result
  end

  defp read(run, args) do
    call = %{
      "type" => "function_call",
      "name" => "read_channel_history",
      "call_id" => Ecto.UUID.generate(),
      "arguments" => Ankole.JSON.encode!(args)
    }

    assert {:ok, tool, args} = Tools.prepare(run, call)
    assert tool.read_only
    result = Tools.execute(run, call, tool, args)
    refute result.is_error
    Tools.attach(run, result)
  end
end
