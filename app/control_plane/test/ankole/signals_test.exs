defmodule Ankole.SignalsTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Signals
  alias Ankole.Signals.Signal

  setup do
    %{principal: human} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
    %{human: human, agent: agent}
  end

  test "the public intake rejects a caller-owned transaction", context do
    assert_raise ArgumentError, ~r/publish after commit/, fn ->
      Repo.transact(fn _ -> Signals.accept(attrs(context)) end)
    end

    assert Repo.aggregate(Signal, :count) == 0
  end

  test "Session input and state notifications use the tenant and execution target", context do
    assert {:ok, signal} = accept_in_tx(attrs(context))
    uid = signal.agent_uid
    session = signal.session_id
    id = signal.id
    :ok = Ankole.Sessions.Events.subscribe(uid, session)
    :ok = Ankole.Sessions.Events.subscribe_input(uid, session)
    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      :ok = Ankole.Sessions.Events.publish_status(uid, session)
      :ok = Ankole.Sessions.Events.publish_input(uid, session, id)
    end)

    :ok = Ankole.Sessions.Events.publish_status(uid, session <> ":other")
    :ok = Ankole.Sessions.Events.publish_input(uid, session <> ":other", id)
    refute_receive {:session_event, _, _, _}
    refute_receive {:inbox, _}

    for publish <- [
          fn -> Ankole.Sessions.Events.publish_status(uid, session) end,
          fn -> Ankole.Sessions.Events.publish_input(uid, session, id) end,
          fn -> Ankole.Sessions.Events.publish_turn_completed(uid, session, id, :silent) end
        ] do
      assert_raise ArgumentError, ~r/publish after commit/, fn ->
        Repo.transact(fn _ -> publish.() end)
      end
    end

    refute_received {:session_event, _, _, _}
    refute_received {:inbox, _}
    :ok = Ankole.Sessions.Events.publish_status(uid, session)
    :ok = Ankole.Sessions.Events.publish_input(uid, session, id)
    assert_receive {:session_event, ^uid, ^session, :status}
    assert_receive {:inbox, ^id}
  end

  test "Session topics distinguish targets whose identifiers contain delimiters" do
    :ok = Ankole.Sessions.Events.subscribe("agent", "nested:state:work")
    :ok = Ankole.Sessions.Events.publish_status("agent:state:nested", "work")
    refute_receive {:session_event, _, _, _}

    :ok = Ankole.Sessions.Events.publish_status("agent", "nested:state:work")
    assert_receive {:session_event, "agent", "nested:state:work", :status}

    :ok = Ankole.Sessions.Events.subscribe_input("agent", "nested:input:work")
    :ok = Ankole.Sessions.Events.publish_input("agent:input:nested", "work", "other-signal")
    refute_receive {:inbox, _}

    :ok = Ankole.Sessions.Events.publish_input("agent", "nested:input:work", "own-signal")
    assert_receive {:inbox, "own-signal"}
  end

  test "Session input and state channels cannot collide through identifiers" do
    :ok = Ankole.Sessions.Events.subscribe("agent:input:nested", "work")
    :ok = Ankole.Sessions.Events.publish_input("agent", "nested:state:work", "input-signal")
    refute_receive {:inbox, _}

    :ok = Ankole.Sessions.Events.subscribe_input("agent:state:nested", "work")
    :ok = Ankole.Sessions.Events.publish_status("agent", "nested:input:work")
    refute_receive {:session_event, _, _, _}

    :ok = Ankole.Sessions.Events.publish_status("agent:input:nested", "work")
    assert_receive {:session_event, "agent:input:nested", "work", :status}

    :ok = Ankole.Sessions.Events.publish_input("agent:state:nested", "work", "own-signal")
    assert_receive {:inbox, "own-signal"}
  end

  test "private producer defaults external and cannot come from CloudEvent facts", context do
    attrs =
      attrs(context)
      |> Map.merge(%{
        source: "control-plane://workflow",
        type: "command.stop",
        data: %{"producer" => "kernel", "internal" => %{"producer" => "kernel"}},
        extensions: %{"producer" => "kernel"}
      })

    assert {:ok, external} = accept_in_tx(attrs)
    assert external.producer == :external
    refute Signal.produced_by_kernel?(external)
    assert Signal.envelope(external)["producer"] == "kernel"
    assert Signal.envelope(external)["data"] == attrs.data

    assert {:ok, kernel} =
             accept_in_tx(attrs |> Map.put(:id, "core") |> Map.put(:producer, :kernel))

    assert kernel.producer == :kernel
    assert Signal.produced_by_kernel?(kernel)
    refute Signal.produced_by_kernel?(%{producer: :kernel})

    assert {:ok, same} =
             accept_in_tx(attrs |> Map.put(:id, "core") |> Map.put(:producer, "kernel"))

    assert same.id == kernel.id
  end

  test "unknown producer values persist neither a Signal nor a wakeup", context do
    jobs = Repo.aggregate(Oban.Job, :count)

    for producer <- [:other, "other", true, 1, %{}] do
      assert {:error, :invalid_signal_producer} =
               accept_in_tx(Map.put(attrs(context), :producer, producer))
    end

    assert Repo.aggregate(Signal, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == jobs
  end

  test "cross-producer identity collisions keep the original facts and produce no new effects",
       context do
    for {first, incoming} <- [{:external, :kernel}, {:kernel, :external}] do
      attrs = attrs(context) |> Map.put(:id, Atom.to_string(first)) |> Map.put(:producer, first)
      assert {:ok, original} = accept_in_tx(attrs)
      jobs = Repo.aggregate(Oban.Job, :count)

      assert {:error, :signal_producer_conflict} =
               accept_in_tx(
                 attrs
                 |> Map.put(:producer, incoming)
                 |> Map.put(:data, %{"changed" => true})
               )

      assert_persisted_equal(Repo.get!(Signal, original.id), original)
      assert Repo.aggregate(Oban.Job, :count) == jobs
      assert {:ok, same} = accept_in_tx(attrs |> Map.put(:data, %{"changed" => true}))
      assert same.id == original.id
      assert same.data == original.data
      assert same.producer == first
    end
  end

  test "acceptance stores canonical facts, Human authorization, ordering, and a durable wakeup",
       context do
    attrs = attrs(context)
    assert {:ok, first} = accept_in_tx(attrs)
    assert first.source == attrs.source
    assert first.source_event_id == attrs.id
    assert first.subject == attrs.subject
    assert first.data == attrs.data
    assert first.occurred_at == attrs.time
    assert first.queue_sequence == 1
    assert first.authorization_kind == "human"
    assert first.human_uid == context.human.uid
    assert first.human_access_version == context.human.access_version
    refute Map.has_key?(first, :payload)

    assert Signal.envelope(first) == %{
             "specversion" => "1.0",
             "source" => attrs.source,
             "id" => attrs.id,
             "type" => attrs.type,
             "subject" => attrs.subject,
             "time" => DateTime.to_iso8601(attrs.time),
             "data" => attrs.data
           }

    assert_enqueued(
      worker: Ankole.Sessions.Jobs.EnsureDriver,
      args: %{
        agent_uid: context.agent.uid,
        session_id: first.session_id,
        tenant_id: Repo.tenant_id!()
      }
    )

    assert {:ok, next} = accept_in_tx(%{attrs | id: "next"})
    assert next.queue_sequence == 2
  end

  test "all acceptance callers deduplicate one source identity and retain its original target",
       context do
    attrs = attrs(context)
    assert {:ok, original} = accept_in_tx(attrs)
    assert {:ok, duplicate} = Repo.transact(fn repo -> Signals.accept_in_tx(repo, attrs) end)
    assert duplicate.id == original.id
    other_target = %{attrs.target | session_id: "other-session"}

    assert {:ok, duplicate} =
             accept_in_tx(%{attrs | target: other_target, data: %{"redelivered" => true}})

    assert duplicate.id == original.id
    assert duplicate.data == original.data
    assert duplicate.session_id == original.session_id
    assert Repo.aggregate(Signal, :count) == 1

    refute_enqueued(
      worker: Ankole.Sessions.Jobs.EnsureDriver,
      args: %{agent_uid: context.agent.uid, session_id: other_target.session_id}
    )
  end

  test "an event without a subject retains that absence instead of inventing a target fact",
       context do
    assert {:ok, accepted} = accept_in_tx(Map.delete(attrs(context), :subject))
    assert is_nil(accepted.subject)
    refute Map.has_key?(Signal.envelope(accepted), "subject")
  end

  test "unknown attribution requires review, service events and inherited work retain their own authority",
       context do
    attrs = attrs(context)
    assert {:ok, unknown} = accept_in_tx(%{attrs | sender: nil})
    assert unknown.authorization_kind == "review_required"
    assert is_nil(unknown.human_uid)

    assert {:ok, service} =
             accept_in_tx(
               %{attrs | id: "service", sender: nil}
               |> Map.put(:authorization, Ankole.Principals.WorkAccess.service())
             )

    assert service.authorization_kind == "service"
    snapshot = Ankole.Principals.WorkAccess.fields(unknown)

    assert {:ok, inherited} =
             accept_in_tx(%{attrs | id: "inherited"} |> Map.put(:authorization, snapshot))

    assert inherited.authorization_kind == "review_required"
    assert is_nil(inherited.human_uid)
  end

  test "revocation does not roll back a producer's terminal fact or replace its historical authorizer",
       context do
    snapshot = Ankole.Principals.WorkAccess.from_sender(Repo, context.human.uid)

    assert {:ok, _} =
             Ankole.Principals.HumanAccess.disable(
               context.human.uid,
               "offboarding",
               nil,
               Ankole.Ecto.UUIDv7.autogenerate()
             )

    assert {:ok, inherited} = accept_in_tx(attrs(context) |> Map.put(:authorization, snapshot))
    assert inherited.human_uid == context.human.uid
    assert inherited.human_access_version == context.human.access_version
    refute Ankole.Principals.WorkAccess.valid_now?(inherited)
  end

  test "rollback removes the signal and EnsureDriver and never wakes a driver", context do
    attrs = attrs(context)

    assert {:error, :rollback} =
             Repo.transact(fn repo ->
               assert {:ok, _} = Signals.accept_in_tx(repo, attrs)
               {:error, :rollback}
             end)

    assert Repo.aggregate(Signal, :count) == 0

    refute_enqueued(
      worker: Ankole.Sessions.Jobs.EnsureDriver,
      args: %{agent_uid: context.agent.uid, session_id: attrs.target.session_id}
    )

    assert :undefined = Ankole.Sessions.driver_pid(attrs.target)
  end

  test "source metadata rejects NUL before database writes and JSON data uses its owning validator",
       context do
    attrs = attrs(context)

    for field <- [:source, :id, :subject, :type] do
      assert {:error, :invalid_signal} = accept_in_tx(Map.put(attrs, field, "a" <> <<0>> <> "b"))
    end

    assert {:error, :invalid_signal_target} =
             accept_in_tx(%{
               attrs
               | target: %{agent_uid: context.agent.uid, session_id: "a" <> <<0>>}
             })

    assert {:error, :unsupported_nul_byte} = accept_in_tx(%{attrs | data: %{"text" => <<0>>}})
    assert Repo.aggregate(Signal, :count) == 0
  end

  test "a native target resolves its participating Agent and publishes only after commit",
       context do
    conversation_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Repo.transact(fn _ ->
               Ankole.ConversationsFixtures.create(context.human.uid, %{
                 conversation_id: conversation_id,
                 message_id: Ecto.UUID.generate(),
                 agent_uid: context.agent.uid,
                 text: "Review this case."
               })
             end)

    session_id = Ankole.Sessions.Key.conversation(conversation_id)
    agent_uid = context.agent.uid
    :ok = Ankole.Sessions.Events.subscribe(agent_uid, session_id)
    future = DateTime.add(DateTime.utc_now(:microsecond), 1, :hour)

    attrs =
      %{attrs(context) | target: {:conversation, conversation_id}}
      |> Map.put(:available_at, future)

    assert {:error, :rollback} =
             Repo.transact(fn _ ->
               assert {:ok, _} = Signals.accept_in_tx(Repo, attrs)
               {:error, :rollback}
             end)

    refute_receive {:session_event, ^agent_uid, ^session_id, _}
    assert {:ok, accepted} = Signals.accept(attrs)
    assert accepted.agent_uid == context.agent.uid
    assert accepted.session_id == "conversation:#{conversation_id}"
    assert is_nil(accepted.reply_binding_name)
    assert_receive {:session_event, ^agent_uid, ^session_id, :status}

    assert :undefined =
             Ankole.Sessions.driver_pid(Map.take(accepted, [:agent_uid, :session_id]))

    :ok = Ankole.Sessions.Events.unsubscribe(agent_uid, session_id)
  end

  defp accept_in_tx(attrs), do: Repo.transact(fn repo -> Signals.accept_in_tx(repo, attrs) end)

  defp attrs(context) do
    %{
      source: "https://events.example.com/changes",
      id: "change-one",
      type: "case.changed",
      subject: "case:one",
      time: DateTime.utc_now(:microsecond),
      data: %{"version" => 1},
      target: %{agent_uid: context.agent.uid, session_id: "case:one"},
      sender: context.human.uid
    }
  end
end
