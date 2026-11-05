defmodule Ankole.Sessions.TurnUsageTest do
  @moduledoc "Checks that a finished turn records the models and tokens of its Signal in the execution record."
  use Ankole.DataCase, async: false
  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  import Ankole.PrincipalsFixtures,
    only: [human_fixture: 1, actor_fixture: 1, worker_provider_fixture: 1]

  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.Conversations
  alias Ankole.Sessions.{Admission, Model, Run}
  alias Ankole.Signals.Signal

  test "the reply's execution record sums every counted round of its Signal" do
    alice = human_fixture(%{display_name: "Alice"}).principal
    agent = Ankole.SessionsCase.agent_fixture(%{owner_principal_uid: alice.uid}).principal
    Ankole.ConversationsFixtures.grant_chat(alice.uid, agent.uid)
    id = Ecto.UUID.generate()

    assert {:ok, _} =
             Conversations.create(actor_fixture(alice), %{
               conversation_id: id,
               agent_uid: agent.uid,
               message_id: Ecto.UUID.generate(),
               text: "Summarize the week."
             })

    event = Repo.one!(from s in Signal, where: s.conversation_id == ^id)

    assert {:ok, run} =
             Admission.admit(%{agent_uid: agent.uid, session_id: event.session_id}, event)

    assert {:ok, {:preparing, run}} = Model.prepare(run)

    for {model, input, output} <- [{"gpt-5.5", 900, 100}, {"gpt-5.5", nil, nil}] do
      assert {:ok, _record} =
               Ankole.Ash.create(UsageRecord, :record_round, %{
                 subject_uid: agent.uid,
                 origin: :agent,
                 model: "turn-usage/#{model}",
                 model_profile: "primary",
                 served_profile: "primary",
                 input_tokens: input,
                 output_tokens: output,
                 signal_id: run.signal_id,
                 human_uid: alice.uid
               })
    end

    assert {:ok, response} =
             start_response_run(%{
               subject_uid: run.agent_uid,
               conversation_id: run.conversation.id,
               round_state: run,
               metadata: %{"request_metadata" => Run.metadata(run)}
             })

    assert {:ok, _response} =
             ResponseCommit.commit_complete(response, [
               %{"type" => "output_text", "text" => "Here is the summary."}
             ])

    assert {:ok, {_state, run}} = Run.restore(run)
    assert {:ok, finalized} = Run.finalize(run)
    reply = Enum.find(finalized.posted.messages, &(&1.text == "Here is the summary."))

    assert %{
             "rounds" => 2,
             "reported_rounds" => 1,
             "input_tokens" => 900,
             "output_tokens" => 100,
             "cached_input_tokens" => nil,
             "models" => [
               %{"model" => "turn-usage/gpt-5.5", "model_profile" => "primary"} = model
             ]
           } = reply.rich_content["execution"]["usage"]

    refute Map.has_key?(model, "served_profile")

    # The Pod API types the same record, so casting it keeps every value.
    execution = reply.rich_content["execution"]
    {:ok, constraints} = Ash.Type.init(Ankole.Pod.Chat.Execution, [])
    assert {:ok, cast} = Ash.Type.cast_input(Ankole.Pod.Chat.Execution, execution, constraints)

    assert {:ok, typed} =
             Ash.Type.apply_constraints(Ankole.Pod.Chat.Execution, cast, constraints)

    assert Ankole.JSON.decode!(Ankole.JSON.encode!(typed)) == execution
  end

  test "work without a requesting Human serves a personal assistant's owner and no one else" do
    owner = human_fixture(%{display_name: "Owner"}).principal
    worker_provider_fixture(%{is_default: true})
    {:ok, %{principal: assistant}} = Ankole.Principals.ensure_personal_assistant(owner.uid)
    team_agent = Ankole.SessionsCase.agent_fixture(%{owner_principal_uid: owner.uid}).principal

    assert Ankole.Principals.served_human_uid(assistant.uid, nil) == owner.uid
    assert Ankole.Principals.served_human_uid(team_agent.uid, nil) == nil
    assert Ankole.Principals.served_human_uid(team_agent.uid, "someone") == "someone"
  end
end
