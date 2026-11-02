defmodule Ankole.Conversations.PeerReplyBatchTest do
  use Ankole.DataCase, async: false

  alias Ankole.{Conversations, Signals}
  alias Ankole.Conversations.Peers
  alias Ankole.Sessions.{Admission, Model, Queue, Run}
  alias Ankole.AIGateway.ResponseCommit
  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  setup do
    human = Ankole.PrincipalsFixtures.human_fixture().principal

    assistant =
      Ankole.SessionsCase.agent_fixture(%{
        type: :personal_assistant,
        owner_principal_uid: human.uid
      }).principal

    colleagues = for _ <- 1..2, do: Ankole.SessionsCase.agent_fixture(%{}).principal
    Enum.each(colleagues, &Ankole.ConversationsFixtures.grant_chat(human.uid, &1.uid))

    %{
      actor: Ankole.PrincipalsFixtures.actor_fixture(human),
      assistant: assistant,
      colleagues: colleagues
    }
  end

  test "two queued reviews of one request share a model input and one durable conclusion", ctx do
    {source, [legal, finance]} = delegate_reviews(ctx)
    first = reply(legal, "Legal approval window is 37 days.")
    second = reply(finance, "Finance budget ceiling is 48000.")
    run = prepare(first)

    assert run.steer_event_ids == [second.id]
    input = Ankole.JSON.encode!(Model.request(run)["input"])
    assert input =~ "Legal approval window is 37 days."
    assert input =~ "Finance budget ceiling is 48000."
    assert input =~ legal.agent_uid
    assert input =~ finance.agent_uid
    assert first.data["root_human_signal_id"] == source.id
    assert second.data["root_human_signal_id"] == source.id

    run = complete_response(run, "Use the 37-day window within the 48000 budget.")
    # Recovery reads the same applied-input identities that finalization consumes.
    assert {:ok, {:boundary, restored}} = Run.restore(run)
    assert restored.steer_event_ids == [second.id]
    assert {:ok, result} = Run.finalize(restored)
    assert MapSet.new(result.input_signal_ids) == MapSet.new([first.id, second.id])
    assert Signals.get_signal!(first.id).final_response_id == Run.response_id(run.model_response)
    assert Signals.get_signal!(second.id).final_response_id == Run.response_id(run.model_response)
    assert Queue.due(first) == []

    assert {:ok, detail} = Conversations.get(ctx.actor, source.conversation_id)

    assert Enum.count(
             detail.messages,
             &(&1.text == "Use the 37-day window within the 48000 budget.")
           ) == 1
  end

  test "a later review is delivered in its own turn instead of being silently consumed", ctx do
    {_source, [legal, finance]} = delegate_reviews(ctx)
    first = reply(legal, "Legal review arrived first.")
    run = prepare(first)
    assert run.steer_event_ids == []

    later = reply(finance, "Finance review arrived while the assistant was composing.")

    assert {:ok, [], run} =
             Run.inject_pending(%{run | pending_event_ids: [later.id]}, fn _ -> true end)

    assert {:ok, _} = run |> complete_response("Here is the legal review.") |> Run.finalize()
    assert Signals.get_signal!(later.id).status == :queued
    assert {:ok, _} = finish(later, "Here is the additional finance review.")
    assert Queue.due(first) == []
  end

  test "another task in the same window is a batch boundary", ctx do
    {source, [legal, finance]} = delegate_reviews(ctx)
    next = human_message(ctx, source.conversation_id, "Now review a different contract.")
    other_review = delegate(next, hd(ctx.colleagues).uid)
    assert {:ok, _} = finish(next, "The second contract is delegated.")

    first = reply(legal, "First contract: legal result.")
    other = reply(other_review, "Second contract: independent result.")
    last = reply(finance, "First contract: finance result.")
    run = prepare(first)

    assert run.steer_event_ids == []
    assert {:ok, _} = run |> complete_response("First contract legal review.") |> Run.finalize()
    assert Enum.map(Queue.due(first), & &1.id) == [other.id, last.id]
    refute Peers.same_task_reply?(first, other)
    assert Peers.same_task_reply?(first, last)
  end

  test "a Human message takes precedence and can steer a batched review", ctx do
    {source, [legal, finance]} = delegate_reviews(ctx)
    first = reply(legal, "Legal result.")
    second = reply(finance, "Finance result.")

    human =
      human_message(ctx, source.conversation_id, "First tell me which result is still missing.")

    assert hd(Queue.due(first)).id == human.id
    human_run = prepare(human)
    assert human_run.steer_event_ids == []

    assert {:ok, _} =
             human_run |> complete_response("Both reviews are available.") |> Run.finalize()

    run = prepare(first)
    assert run.steer_event_ids == [second.id]

    correction =
      human_message(ctx, source.conversation_id, "Use a budget of 42000 in the conclusion.")

    assert {:ok, [injected], run} =
             Run.inject_pending(%{run | pending_event_ids: [correction.id]}, fn _ -> true end)

    assert injected.id == correction.id
    assert run.steer_event_ids == [second.id, correction.id]
    assert Ankole.JSON.encode!(Model.request(run)["input"]) =~ "42000"

    assert {:ok, result} =
             run |> complete_response("The combined conclusion uses 42000.") |> Run.finalize()

    assert MapSet.new(result.input_signal_ids) == MapSet.new([first.id, second.id, correction.id])
  end

  test "stopping the combined turn settles its reviews without consuming a later arrival", ctx do
    {source, [legal, finance]} = delegate_reviews(ctx)
    first = reply(legal, "Legal result.")
    second = reply(finance, "Finance result.")
    run = prepare(first)
    extra_review = delegate(source, hd(ctx.colleagues).uid)
    later = reply(extra_review, "An additional finding arrived later.")

    assert {:ok, result} = Run.finalize(run, :stopped)
    assert MapSet.new(result.input_signal_ids) == MapSet.new([first.id, second.id])

    for event <- [first, second], do: assert(Signals.get_signal!(event.id).status == :completed)

    assert Enum.any?(
             result.posted.messages,
             &(&1.rich_content["execution"]["status"] == "stopped")
           )

    assert Signals.get_signal!(later.id).status == :queued
  end

  test "different windows, hop budgets and priority instructions cannot join the batch", ctx do
    {_source, [legal, finance]} = delegate_reviews(ctx)
    first = reply(legal, "Legal result.")
    second = reply(finance, "Finance result.")
    {_other_source, [other_legal | _]} = delegate_reviews(ctx)
    other = reply(other_legal, "Another window's review.")

    refute Peers.same_task_reply?(first, other)
    refute Peers.same_task_reply?(first, %{second | data: Map.put(second.data, "priority", true)})

    refute Peers.same_task_reply?(first, %{
             second
             | data: Map.put(second.data, "peer_hop_count", 6)
           })

    assert prepare(first).steer_event_ids == [second.id]
    assert Signals.get_signal!(other.id).status == :queued
  end

  defp delegate_reviews(ctx) do
    id = Ecto.UUID.generate()
    message = Ecto.UUID.generate()

    Ankole.SessionsCase.stub_driver(%{
      agent_uid: ctx.assistant.uid,
      session_id: Ankole.Sessions.Key.conversation(id)
    })

    assert {:ok, _} =
             Conversations.create(ctx.actor, %{
               conversation_id: id,
               message_id: message,
               agent_uid: ctx.assistant.uid,
               text:
                 "Ask legal and finance to review this contract, then combine their conclusions."
             })

    [source] = Signals.list_signals!(query: [filter: [message_id: message]])
    reviews = Enum.map(ctx.colleagues, &delegate(source, &1.uid))
    assert {:ok, _} = finish(source, "Both colleagues are reviewing the contract.")
    {source, reviews}
  end

  defp human_message(ctx, id, text) do
    message_id = Ecto.UUID.generate()
    assert {:ok, _} = Conversations.post(ctx.actor, id, %{message_id: message_id, text: text})
    [event] = Signals.list_signals!(query: [filter: [message_id: message_id]])
    event
  end

  defp delegate(source, uid) do
    run = %{
      agent_uid: source.agent_uid,
      session_id: source.session_id,
      signal_id: source.id,
      event: source
    }

    assert {:ok, result} =
             Repo.transact_top_level(fn ->
               with {:ok, keys, commit} <-
                      Peers.prepare_send(run, %{
                        "target_agent_uid" => uid,
                        "message" => "Review this contract."
                      }),
                    :ok <- Queue.lock_sessions_in_tx(keys),
                    {:ok, result, _} <- commit.(),
                    do: {:ok, result}
             end)

    Signals.list_signals!(
      query: [
        filter: [conversation_id: result.details.exchange_id],
        sort: [queue_sequence: :desc]
      ]
    )
    |> hd()
  end

  defp reply(event, text) do
    assert {:ok, %{posted: %{signals: [wake]}}} = finish(event, text)
    wake
  end

  defp prepare(event) do
    assert {:ok, run} = Admission.admit(event, event)
    assert {:ok, {:preparing, run}} = Model.prepare(run)
    run
  end

  defp finish(event, text), do: event |> prepare() |> complete_response(text) |> Run.finalize()

  defp complete_response(run, text) do
    assert {:ok, response} =
             start_response_run(%{
               subject_uid: run.agent_uid,
               conversation_id: run.conversation.id,
               round_state: run,
               metadata: %{"request_metadata" => Run.metadata(run)}
             })

    assert {:ok, response} =
             ResponseCommit.commit_complete(response, [%{"type" => "output_text", "text" => text}])

    %{run | model_response: response, anchor: response.id}
  end
end
