defmodule Ankole.Sessions.ConversationContextTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.AIGatewayCase, only: [start_response_run: 1]
  alias Ankole.AIGateway
  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.Sessions.{ConversationContext, ModelHistory}

  alias Ankole.Conversations
  alias Ankole.Signals

  setup do
    %{principal: human} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})

    attrs = %{
      conversation_id: Ecto.UUID.generate(),
      message_id: Ecto.UUID.generate(),
      agent_uid: agent.uid,
      text: "First question"
    }

    {:ok, detail} = Ankole.ConversationsFixtures.create(human.uid, attrs)

    %{
      human: human,
      agent: agent,
      conversation: detail.conversation,
      model_conversation_id: detail.model_conversation_id,
      first_id: attrs.message_id
    }
  end

  test "a report from this Agent's cron session is new context, while own replies and signal input are excluded",
       context do
    session_id = session_key(context)
    first = Repo.get_by!(Ankole.Signals.Signal, message_id: context.first_id)

    {:ok, %{messages: [own]}} =
      in_tx(fn ->
        Ankole.ConversationsFixtures.post_statement_in_tx(Repo, first, "Own answer")
      end)

    cron = append_report(context, "Cron report")
    next_id = Ecto.UUID.generate()

    {:ok, _} =
      Ankole.ConversationsFixtures.post(context.human.uid, context.conversation.id, %{
        message_id: next_id,
        text: "Next question"
      })

    assert {:ok, snapshot} =
             Conversations.context_snapshot(
               context.conversation.id,
               session_id,
               0,
               [context.first_id, next_id]
             )

    assert Enum.map(snapshot.messages, & &1.id) == [cron.id]
    assert cron.author_uid == own.author_uid
    assert cron.session_id != own.session_id
    assert snapshot.max_seq == 4
  end

  test "the bound keeps the latest reports in sequence order and advances past the older omitted reports",
       context do
    reports = for index <- 1..4, do: append_report(context, "Report #{index}")

    assert {:ok, snapshot} =
             Conversations.context_snapshot(
               context.conversation.id,
               session_key(context),
               0,
               [context.first_id],
               limit: 2
             )

    assert Enum.map(snapshot.messages, & &1.id) == Enum.map(Enum.take(reports, -2), & &1.id)
    assert snapshot.max_seq == 5

    assert {:ok, %{messages: [], max_seq: 5}} =
             Conversations.context_snapshot(
               context.conversation.id,
               session_key(context),
               snapshot.max_seq,
               []
             )
  end

  test "a statement committed after the recorded snapshot enters the next request", context do
    first_report = append_report(context, "Before the request")
    session_id = session_key(context)

    assert {:ok, first} =
             Conversations.context_snapshot(context.conversation.id, session_id, 0, [
               context.first_id
             ])

    assert Enum.map(first.messages, & &1.id) == [first_report.id]

    late_report = append_report(context, "During execution")

    assert {:ok, next} =
             Conversations.context_snapshot(
               context.conversation.id,
               session_id,
               first.max_seq,
               []
             )

    assert Enum.map(next.messages, & &1.id) == [late_report.id]
  end

  test "a missing watermark reads the same bounded reports again",
       context do
    report = append_report(context, "Keep this report")
    session_id = session_key(context)

    assert {:ok, consumed} =
             Conversations.context_snapshot(context.conversation.id, session_id, 0, [
               context.first_id
             ])

    assert {:ok, %{messages: []}} =
             Conversations.context_snapshot(
               context.conversation.id,
               session_id,
               consumed.max_seq,
               []
             )

    assert {:ok, restored} =
             Conversations.context_snapshot(context.conversation.id, session_id, 0, [
               context.first_id
             ])

    assert Enum.map(restored.messages, & &1.id) == [report.id]
  end

  test "caller metadata records consumed reports and a retracted visible round reads them again",
       context do
    report = append_report(context, "Read this public report")
    run = context_run(context)
    first = ConversationContext.append(run, %{"metadata" => %{}, "input" => []})

    assert first["metadata"]["conversation_read"]["id"] == context.conversation.id
    assert first["metadata"]["conversation_read"]["max_seq"] == 2

    assert MapSet.new(first["metadata"]["conversation_read"]["message_ids"]) ==
             MapSet.new([context.first_id, report.id])

    assert Ankole.JSON.encode!(first["input"]) =~ report.text

    {:ok, response} =
      start_response_run(%{
        subject_uid: context.agent.uid,
        conversation_id: context.model_conversation_id,
        metadata: %{"request_metadata" => first["metadata"]}
      })

    {:ok, response} = ResponseCommit.commit_complete(response, [])

    assert ConversationContext.read_seq(
             context.agent.uid,
             context.model_conversation_id,
             context.conversation.id
           ) == 2

    assert ConversationContext.append(run, %{"metadata" => %{}, "input" => []})["input"] == []

    assert {:ok, %{status: :retracted}} =
             in_tx(fn ->
               AIGateway.retract_visible_suffix_in_tx(
                 Repo,
                 context.agent.uid,
                 context.model_conversation_id,
                 ["resp_#{response.id}"]
               )
             end)

    repeated = ConversationContext.append(run, %{"metadata" => %{}, "input" => []})
    assert Ankole.JSON.encode!(repeated["input"]) =~ report.text
  end

  test "ending model history naturally gives the next model conversation no read position",
       context do
    report = append_report(context, "Report before reset")

    {:ok, response} =
      start_response_run(%{
        subject_uid: context.agent.uid,
        conversation_id: context.model_conversation_id,
        metadata: %{
          "request_metadata" => %{
            "conversation_read" => %{"id" => context.conversation.id, "max_seq" => report.seq}
          }
        }
      })

    {:ok, _} = ResponseCommit.commit_complete(response, [])
    session = Ankole.Sessions.Key.conversation(context.conversation.id)

    assert {:ok, _} =
             in_tx(fn ->
               ModelHistory.end_active_conversation_in_tx(
                 Repo,
                 context.agent.uid,
                 session,
                 DateTime.utc_now(:microsecond)
               )
             end)

    assert {:ok, successor} =
             in_tx(fn ->
               AIGateway.ensure_conversation_in_tx(Repo, context.agent.uid, session)
             end)

    assert successor.id != context.model_conversation_id
    run = %{context_run(context) | conversation: successor}

    assert Ankole.JSON.encode!(
             ConversationContext.append(run, %{"metadata" => %{}, "input" => []})["input"]
           ) =~ report.text
  end

  for change <- [:edit, :remove] do
    test "#{change} preserves completed model input and keeps the read watermark", context do
      report = append_report(context, "Background before execution")
      run = context_run(context)
      first = ConversationContext.append(run, %{"metadata" => %{}, "input" => []})

      {:ok, response} =
        start_response_run(%{
          subject_uid: context.agent.uid,
          conversation_id: context.model_conversation_id,
          request_items: first["input"],
          metadata: %{
            "request_metadata" => Map.put(first["metadata"], "signal_id", run.signal_id)
          }
        })

      {:ok, response} = ResponseCommit.commit_complete(response, [])

      case unquote(change) do
        :edit ->
          report
          |> Ankole.Conversations.Message.changeset(%{text: "Edited later"})
          |> Repo.update!()

        :remove ->
          Repo.delete!(report)
      end

      assert Repo.reload!(response) == response
      assert Enum.any?(response.content, &(Ankole.JSON.encode!(&1) =~ report.text))
      assert ConversationContext.append(run, %{"metadata" => %{}, "input" => []})["input"] == []
    end
  end

  test "terminal checks distinguish withdrawn background from the current input", context do
    report = append_report(context, "Background read by this round")
    run = context_run(context)
    first = ConversationContext.append(run, %{"metadata" => %{}, "input" => []})

    {:ok, response} =
      start_response_run(%{
        subject_uid: context.agent.uid,
        conversation_id: context.model_conversation_id,
        request_items: first["input"],
        metadata: %{"request_metadata" => Map.put(first["metadata"], "signal_id", run.signal_id)}
      })

    {:ok, _} = ResponseCommit.commit_complete(response, [])
    signal = Repo.get!(Signals.Signal, run.signal_id)

    report
    |> Ankole.Conversations.Message.changeset(%{text: "Edited while generating"})
    |> Repo.update!()

    assert :ok =
             Ankole.Sessions.Queue.ensure_event_source_live_in_tx(
               Repo,
               signal,
               DateTime.utc_now()
             )

    Repo.delete!(report)

    assert {:error, :signal_context_canceled} =
             Ankole.Sessions.Queue.ensure_event_source_live_in_tx(
               Repo,
               signal,
               DateTime.utc_now()
             )
  end

  defp session_key(context),
    do: %{
      agent_uid: context.agent.uid,
      session_id: Ankole.Sessions.Key.conversation(context.conversation.id)
    }

  defp context_run(context) do
    %{
      agent_uid: context.agent.uid,
      session_id: Ankole.Sessions.Key.conversation(context.conversation.id),
      signal_id: Repo.get_by!(Ankole.Signals.Signal, message_id: context.first_id).id,
      steer_event_ids: [],
      conversation: %{id: context.model_conversation_id}
    }
  end

  defp append_report(context, text) do
    signal_id = Ecto.UUID.generate()

    in_tx(fn ->
      {:ok, signal} =
        Signals.accept_in_tx(Repo, %{
          producer: :kernel,
          source: "schedule:cron:context-test",
          id: signal_id,
          type: "cron.fire",
          subject: "context-test",
          target: %{agent_uid: context.agent.uid, session_id: "cron:context-test"},
          sender: context.human.uid,
          data: %{"wake_payload" => %{"cron_schedule_name" => "Context report"}}
        })

      Ankole.ConversationsFixtures.post_statement_in_tx(Repo, signal, text,
        conversation_id: context.conversation.id
      )
    end)
    |> elem(1)
    |> Map.fetch!(:messages)
    |> List.first()
  end

  defp in_tx(operation), do: Repo.transact(fn _repo -> operation.() end)
end
