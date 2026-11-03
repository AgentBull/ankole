defmodule Ankole.PeerConversationsIntegrationTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  alias Ankole.{Conversations, Signals}
  alias Ankole.Conversations.Peers
  alias Ankole.Sessions.{Admission, Model, Run, Queue}
  alias Ankole.AIGateway.ResponseCommit
  import Ankole.AIGatewayCase, only: [start_response_run: 1]
  import Ankole.PrincipalsFixtures, only: [human_fixture: 0, actor_fixture: 1]

  setup %{tenant: tenant} do
    human = human_fixture().principal

    assistant =
      Ankole.SessionsCase.agent_fixture(%{
        type: :personal_assistant,
        owner_principal_uid: human.uid
      }).principal

    colleague = Ankole.SessionsCase.agent_fixture(%{}).principal
    Ankole.ConversationsFixtures.grant_chat(human.uid, colleague.uid)

    on_exit(fn ->
      Repo.with_tenant(tenant.id, fn ->
        Ankole.PrincipalsFixtures.delete_agent_fixture_rows(assistant.uid)
        Ankole.PrincipalsFixtures.delete_agent_fixture_rows(colleague.uid)
        cleanup_tenant!(tenant)
      end)
    end)

    %{actor: actor_fixture(human), assistant: assistant, colleague: colleague}
  end

  test "simultaneous first messages commit one canonical DM and keep every input", ctx do
    replies =
      parallel(
        ctx,
        for number <- 1..8 do
          fn -> create(ctx.actor, ctx.colleague.uid, "Input #{number}") end
        end
      )

    ids = Enum.map(replies, fn {:ok, detail} -> detail.conversation.id end) |> Enum.uniq()
    assert [id] = ids
    assert Conversations.get_conversation!(id).sequence_high_water == 8
    assert length(Signals.list_signals!(query: [filter: [conversation_id: id]])) == 8
  end

  test "a new delegation and a colleague reply serialize on both sessions without losing either result",
       ctx do
    {:ok, origin} = create(ctx.actor, ctx.assistant.uid, "Review contract")
    [source] = Signals.list_signals!(query: [filter: [conversation_id: origin.conversation.id]])
    {:ok, id} = send_peer(source, ctx.colleague.uid)
    [peer] = Signals.list_signals!(query: [filter: [conversation_id: id]])
    assert {:ok, run} = Admission.admit(peer, peer)
    assert {:ok, {:preparing, run}} = Model.prepare(run)

    assert {:ok, response} =
             start_response_run(%{
               subject_uid: run.agent_uid,
               conversation_id: run.conversation.id,
               round_state: run,
               metadata: %{"request_metadata" => Run.metadata(run)}
             })

    assert {:ok, response} =
             ResponseCommit.commit_complete(response, [
               %{"type" => "output_text", "text" => "Review complete"}
             ])

    run = %{run | model_response: response, anchor: response.id}

    [sent, replied] =
      parallel(ctx, [
        fn -> send_peer(source, ctx.colleague.uid) end,
        fn -> Run.finalize(run) end
      ])

    assert {:ok, ^id} = sent
    assert {:ok, %{posted: %{signals: [wake]}}} = replied
    assert wake.conversation_id == origin.conversation.id
    assert length(Peers.exchanges([origin.conversation.id])) == 1
    assert length(Signals.list_signals!(query: [filter: [conversation_id: id]])) == 2

    assert length(
             Signals.list_signals!(
               query: [
                 filter: [conversation_id: origin.conversation.id, type: "agent.peer_message"]
               ]
             )
           ) == 1
  end

  defp create(actor, agent, text) do
    Conversations.create(actor, %{
      conversation_id: Ecto.UUID.generate(),
      message_id: Ecto.UUID.generate(),
      agent_uid: agent,
      text: text
    })
  end

  defp send_peer(source, colleague) do
    run = %{
      agent_uid: source.agent_uid,
      session_id: source.session_id,
      signal_id: source.id,
      event: source
    }

    Repo.transact_top_level(fn ->
      with {:ok, keys, commit} <-
             Peers.prepare_send(run, %{
               "target_agent_uid" => colleague,
               "message" => "Review contract"
             }),
           :ok <- Queue.lock_sessions_in_tx(keys),
           {:ok, result, _notifications} <- commit.(),
           do: {:ok, result.details.exchange_id}
    end)
  end

  defp parallel(ctx, functions) do
    tasks =
      Enum.map(functions, fn fun ->
        Task.async(fn ->
          receive do
            :start -> Repo.with_tenant(ctx.tenant.id, fun)
          end
        end)
      end)

    Enum.each(tasks, &send(&1.pid, :start))
    Enum.map(tasks, &Task.await(&1, 30_000))
  end
end
