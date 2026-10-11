defmodule Ankole.Conversations.ChannelHistoryTest do
  use Ankole.SignalsGateway.ActorRuntimeCase
  alias Ankole.Conversations.{Admission, Context, ToolCatalog, Tools}
  alias Ankole.SignalsGateway.{ChannelContext, Entry}

  setup {Ankole.SignalsGateway.ActorRuntimeCase, :use_mock_signal_provider_plugin}

  test "read_channel_history pages the current channel oldest first and filters by text" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    {:ok, %{actor_event: input}} =
      emit_entry(agent.uid, "bot", group_entry(%{text: "Summarize this week", explicit: true}),
        now: @base_time
      )

    channel_id = input.signal_channel_id

    for day <- 1..3 do
      at = DateTime.add(@base_time, -day * 86_400)

      %Entry{}
      |> Entry.changeset(%{
        document_id: "history-#{day}",
        signal_channel_id: channel_id,
        source_entry_id: "history-#{day}",
        text: "Decision #{day}: ship release #{day}",
        author: %{"display_name" => "Lin"},
        provider_time: at,
        first_seen_at: at,
        last_seen_at: at
      })
      |> Repo.insert!()
    end

    {:ok, run} = Admission.admit(input, input)
    {:ok, context} = Context.resolve(run.agent_uid, run.session_id)
    {tools, _hosted} = ToolCatalog.for_run(%{run | context: context})
    run = %{run | context: context, tools: tools, pages: %{}, todo: [], web_cache: %{}}

    {run, first} = read(run, %{"query" => "DECISION", "until" => DateTime.to_iso8601(@base_time)})

    assert [%{"text" => "Decision 3: ship release 3", "speaker" => "Lin"} | _] =
             first.details["messages"]

    assert length(first.details["messages"]) == 3
    assert first.details["next_page"] == nil

    # A one-message page continues from its cursor.
    page = ChannelContext.history_page(channel_id, query: "decision")
    assert length(page.messages) == 3

    {_run, since} =
      read(run, %{"since" => DateTime.to_iso8601(DateTime.add(@base_time, -2 * 86_400))})

    assert Enum.map(since.details["messages"], & &1["text"]) == [
             "Decision 2: ship release 2",
             "Decision 1: ship release 1",
             "Summarize this week"
           ]
  end

  test "the history pages at its row limit and resumes after the cursor" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    {:ok, %{actor_event: input}} =
      emit_entry(agent.uid, "bot", group_entry(%{text: "start", explicit: true}), now: @base_time)

    for index <- 1..205 do
      at = DateTime.add(@base_time, index)

      %Entry{}
      |> Entry.changeset(%{
        document_id: "page-#{index}",
        signal_channel_id: input.signal_channel_id,
        source_entry_id: "page-#{index}",
        text: "message #{index}",
        author: %{},
        provider_time: at,
        first_seen_at: at,
        last_seen_at: at
      })
      |> Repo.insert!()
    end

    first = ChannelContext.history_page(input.signal_channel_id, query: "message")
    assert length(first.messages) == 200
    assert is_binary(first.next_cursor)

    rest =
      ChannelContext.history_page(input.signal_channel_id,
        query: "message",
        cursor: first.next_cursor
      )

    assert Enum.map(rest.messages, & &1["text"]) == Enum.map(201..205, &"message #{&1}")
    assert rest.next_cursor == nil
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
