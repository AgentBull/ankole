defmodule Ankole.Sessions.NativeConversationTest do
  use Ankole.DataCase, async: false

  import Ankole.SessionsCase, only: [agent_fixture: 1]
  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.Conversations
  alias Ankole.Conversations.Message
  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Commands
  alias Ankole.Sessions.Model
  alias Ankole.Sessions.Notices
  alias Ankole.Sessions.Run
  alias Ankole.Signals.Signal
  alias Ankole.Signals.Binding
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Sessions.ModelHistory

  setup do
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
    id = Ecto.UUID.generate()

    assert {:ok, detail} =
             Repo.transact(fn _repo ->
               Ankole.ConversationsFixtures.create(human.uid, %{
                 conversation_id: id,
                 agent_uid: agent.uid,
                 message_id: Ecto.UUID.generate(),
                 text: "Explain the current project."
               })
             end)

    event = Repo.one!(Signal)
    key = %{agent_uid: agent.uid, session_id: event.session_id}
    assert :ok = Conversations.subscribe(id)

    %{human: human, agent: agent, id: id, event: event, key: key, detail: detail}
  end

  test "native input has the Human's authority and starts without an IM route", context do
    assert Ankole.Sessions.status(context.key).state == :queued
    run = prepare(context)
    assert run.event.human_uid == context.human.uid
    assert run.event.conversation_id == context.id
    assert Ankole.Sessions.status(context.key).state == :running
    assert_receive {:conversation_event, id, :status}
    assert id == context.id

    assert Ankole.Sessions.Prompt.Input.text(Signal.envelope(run.event), run.event.type) ==
             "Explain the current project."

    assert_no_adapter_rows()
  end

  test "completion commits one public reply and emits message and idle status", context do
    run = context |> prepare() |> respond("The project has one durable owner.")
    assert {:ok, result} = Run.finalize(run)

    assert %Message{text: "The project has one durable owner.", kind: :message} =
             result.posted.messages |> List.first()

    assert {:ok, detail} = Conversations.get(context.human.uid, context.id)
    assert Enum.map(detail.messages, & &1.seq) == [1, 2]
    reply = List.last(detail.messages)
    assert reply.author_uid == context.agent.uid
    assert reply.signal_id == context.event.id
    assert reply.session_id == context.key.session_id
    assert reply.reply_to_message_id == hd(detail.messages).id
    assert Ankole.Sessions.status(context.key) == %{state: :idle, retry_at: nil}
    assert Repo.reload!(context.event).completed_at
    assert_receive {:conversation_event, _, :message}
    assert_receive {:conversation_event, _, :status}
    assert {:error, :run_closed} = Run.finalize(run)
    assert Repo.aggregate(Message, :count) == 2
    assert_no_adapter_rows()
  end

  test "silent completion closes its signal without a message event", context do
    run = prepare(context)
    assert_receive {:conversation_event, _, :status}
    assert {:ok, _} = Run.finalize(run, :silent)
    assert Ankole.Sessions.status(context.key).state == :idle
    assert Repo.aggregate(Message, :count) == 1
    refute_receive {:conversation_event, _, :message}
    assert_receive {:conversation_event, _, :status}
    assert_no_adapter_rows()
  end

  test "dead letter is an immutable notice in the native conversation", context do
    run = prepare(context)
    assert {:ok, result} = Run.finalize(run, :dead_letter, %{"code" => "test_failure"})
    assert %Message{kind: :notice, text: text} = result.posted.messages |> List.first()
    assert is_binary(text) and text != ""
    assert Repo.reload!(context.event).input_state == "dead_letter"
    assert Ankole.Sessions.status(context.key).state == :idle
    assert_receive {:conversation_event, _, :message}
    assert_no_adapter_rows()
  end

  test "a retry records its deadline and broadcasts after commit", context do
    run = prepare(context)
    assert_receive {:conversation_event, _, :status}
    assert {:ok, event} = Run.defer_retry(run, %{"code" => "temporary_failure"})

    assert Ankole.Sessions.status(context.key) == %{
             state: :retrying,
             retry_at: event.available_at
           }

    assert_receive {:conversation_event, _, :status}
    refute_receive {:conversation_event, _, :message}
  end

  test "a retry in a caller transaction publishes only after commit", context do
    run = prepare(context)
    assert_receive {:conversation_event, _, :status}
    error = %{"code" => "temporary_failure"}
    now = DateTime.utc_now(:microsecond)

    assert_raise ArgumentError, ~r/use the _in_tx entry point/, fn ->
      Repo.transact(fn _repo -> Run.defer_retry(run, error, now) end)
    end

    assert {:error, :rollback} =
             Repo.transact(fn repo ->
               assert {:ok, _} = Run.defer_retry_in_tx(repo, run, error, now)
               refute_receive {:conversation_event, _, _}
               {:error, :rollback}
             end)

    assert Repo.reload!(context.event).available_at == run.event.available_at
    refute_receive {:conversation_event, _, _}

    assert {:ok, retried} =
             Repo.transact(fn repo -> Run.defer_retry_in_tx(repo, run, error, now) end)

    refute_receive {:conversation_event, _, _}
    Run.after_finalization({:ok, %{signal: retried, status: :deferred}})
    assert_receive {:conversation_event, _, :status}

    assert Ankole.Sessions.status(context.key) == %{
             state: :retrying,
             retry_at: retried.available_at
           }
  end

  test "ready input and a running turn take priority over an earlier waiting retry", context do
    run = prepare(context)
    assert {:ok, retry} = Run.defer_retry(run, %{"code" => "temporary_failure"})

    assert Ankole.Sessions.status(context.key) == %{
             state: :retrying,
             retry_at: retry.available_at
           }

    followup = queued_followup(context)
    assert Ankole.Sessions.status(context.key) == %{state: :queued, retry_at: nil}
    assert {:ok, current} = Admission.admit(context.key, followup)
    assert Ankole.Sessions.status(context.key) == %{state: :running, retry_at: nil}

    assert {:ok, _} = Run.finalize(current, :silent)

    assert Ankole.Sessions.status(context.key) == %{
             state: :retrying,
             retry_at: retry.available_at
           }

    assert_no_adapter_rows()
  end

  test "rollback publishes no completion and leaves no public reply", context do
    run = context |> prepare() |> respond("Only committed text is public.")
    assert_receive {:conversation_event, _, :status}

    assert {:error, :rollback} =
             Repo.transact(fn repo ->
               assert {:ok, _} = Run.finalize_in_tx(repo, run, :loop_finished, nil)
               refute_receive {:conversation_event, _, _}
               {:error, :rollback}
             end)

    assert Repo.aggregate(Message, :count) == 1
    assert is_nil(Repo.reload!(context.event).completed_at)
    refute_receive {:conversation_event, _, _}
    assert {:ok, _} = Run.finalize(run)
    assert_receive {:conversation_event, _, :message}
    assert_no_adapter_rows()
  end

  test "native follow-up is steered into the current Run and consumed with it", context do
    run = prepare(context)
    text = "Focus on the queue instead."

    assert {:ok, _} =
             Repo.transact(fn _repo ->
               Ankole.ConversationsFixtures.post(context.human.uid, context.id, %{
                 message_id: Ecto.UUID.generate(),
                 text: text
               })
             end)

    followup = Repo.one!(from e in Signal, where: e.id != ^context.event.id)
    assert Commands.injectable?(followup)

    assert {:ok, [injected], run} =
             Run.inject_pending(%{run | pending_event_ids: [followup.id]}, fn _ -> true end)

    assert injected.id == followup.id
    assert run.steer_event_ids == [followup.id]
    assert List.last(run.input)["content"] |> Enum.any?(&(&1["text"] == text))
    run = respond(run, "The queue is durable.")

    assert Ankole.Sessions.response_signal_ids(%{
             response_id: Run.response_id(run.model_response),
             metadata: Run.metadata(run)
           }) == [context.event.id, followup.id]

    assert {:ok, result} = Run.finalize(run)
    assert result.posted.messages |> List.first() |> Map.fetch!(:signal_id) == followup.id
    assert Repo.reload!(context.event).completed_at
    assert Repo.reload!(followup).completed_at
    assert Repo.aggregate(Message, :count) == 3
    assert_no_adapter_rows()
  end

  test "native model conversations are not daily-reset candidates", context do
    run = prepare(context)

    assert [] ==
             ModelHistory.daily_reset_candidates_in_tx(
               Repo,
               DateTime.add(DateTime.utc_now(:microsecond), 1, :day)
             )

    assert run.conversation.conversation_key == context.key.session_id
  end

  test "inbox authorization publishes a suspended follow-up notice after commit", context do
    prepare(context)
    assert_receive {:conversation_event, _, :status}
    followup = queued_followup(context)
    suspend_tenant()

    assert {:ok, %Signal{producer: :kernel, completed_at: %DateTime{}}} =
             Admission.authorize_event(followup)

    assert %Message{kind: :notice} = Repo.get_by!(Message, signal_id: followup.id)
    assert_receive {:conversation_event, _, :message}
    assert_receive {:conversation_event, _, :status}
    assert is_nil(Repo.reload!(context.event).completed_at)
    assert_no_adapter_rows()
  end

  test "injection preserves suspended follow-up effects and suppresses them on rollback",
       context do
    run = prepare(context)
    assert_receive {:conversation_event, _, :status}
    followup = queued_followup(context)
    suspend_tenant()

    assert {:error, :rollback} =
             Repo.transact(fn repo ->
               assert {:ok, {[], [_]}} =
                        Run.inject_in_tx(repo, run, [followup], DateTime.utc_now(:microsecond))

               refute_receive {:conversation_event, _, _}
               {:error, :rollback}
             end)

    assert is_nil(Repo.reload!(followup).completed_at)
    refute Repo.get_by(Message, signal_id: followup.id)

    assert {:ok, []} = Run.inject(run, [followup])
    assert %Message{kind: :notice} = Repo.get_by!(Message, signal_id: followup.id)
    assert_receive {:conversation_event, _, :message}
    assert_receive {:conversation_event, _, :status}
    assert Repo.reload!(followup).completed_at
    assert is_nil(Repo.reload!(context.event).completed_at)
    assert_no_adapter_rows()
  end

  test "admission failure leaves a visible native notice", context do
    assert {:ok, result} =
             Notices.finalize(
               {:error, {:model_profile_unavailable, "primary", :not_configured}},
               context.event,
               DateTime.utc_now(:microsecond)
             )
             |> Run.after_finalization()

    assert result.signal.completed_at
    assert %Message{kind: :notice} = List.first(result.posted.messages)
    assert_receive {:conversation_event, _, :message}
    assert_no_adapter_rows()
  end

  test "native turns do not advertise attachment delivery or image generation", context do
    run = prepare(context)
    refute Enum.any?(run.tools, &(&1.name == "reply_attachment"))

    assert {[], [%{"type" => "brain", "inject" => true}]} =
             Ankole.Sessions.Main.tools(
               run,
               [%{"name" => "reply_attachment"}],
               [%{"type" => "image_generation"}, %{"type" => "brain"}]
             )

    refute Ankole.Sessions.Main.instructions(run) =~
             "deliver it with reply_attachment using drive_path"
  end

  defp prepare(context) do
    assert {:ok, run} = Admission.admit(context.key, context.event)
    assert {:ok, {:preparing, run}} = Model.prepare(run)
    run
  end

  defp queued_followup(context) do
    assert {:ok, _} =
             Repo.transact(fn _repo ->
               Ankole.ConversationsFixtures.post(context.human.uid, context.id, %{
                 message_id: Ecto.UUID.generate(),
                 text: "A follow-up before suspension."
               })
             end)

    Repo.one!(from e in Signal, where: e.id != ^context.event.id)
  end

  defp suspend_tenant do
    Repo.get!(Ankole.Tenants.Tenant, Repo.tenant_id!())
    |> Ecto.Changeset.change(suspended_at: DateTime.utc_now(:microsecond))
    |> Repo.update!()
  end

  defp respond(run, text) do
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

  defp assert_no_adapter_rows do
    for schema <- [Binding, Ankole.Conversations.ExternalMessageRef, Intent],
        do: assert(Repo.aggregate(schema, :count) == 0)
  end
end
