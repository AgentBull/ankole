defmodule Ankole.Sessions.ScheduledTest do
  use Ankole.SessionsCase

  alias Ankole.Sessions.Scheduled
  alias Ankole.Schedule.Schemas.ScheduledEvent

  describe "schedule producer correlation" do
    test "a guessed future fire identity cannot make a schedule adopt an external Signal" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      source = Ankole.WorkFixtures.service_source(agent.uid)
      due_at = DateTime.add(@base_time, 5, :minute)

      {:ok, %{scheduled_event: scheduled}} =
        Ankole.Schedule.create_check_back_later(
          %{
            source_signal_id: source.id,
            agent_uid: agent.uid,
            session_id: "checkback-proof",
            tool_call_id: "check-collision",
            idempotency_key: Ecto.UUID.generate(),
            schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "UTC"},
            reason: "Follow up",
            check: "Report changes"
          },
          now: @base_time
        )

      {:ok, external} =
        Repo.transact(fn repo ->
          Ankole.Signals.accept_in_tx(repo, %{
            source: "control-plane://schedule/check_back_later",
            id: "check_back_later:#{scheduled.id}:wakeup",
            type: "check_back_later.wakeup",
            data: %{"external" => "unchanged"},
            target: %{agent_uid: agent.uid, session_id: scheduled.session_id},
            authorization: Ankole.Principals.WorkAccess.service()
          })
        end)

      assert {:error, :signal_producer_conflict} =
               Ankole.Schedule.fire_due_event(scheduled.id, now: due_at)

      assert Repo.get!(Signal, external.id).data == external.data
      assert Repo.get!(Signal, external.id).producer == :external
      stored = Repo.get!(ScheduledEvent, scheduled.id)
      assert is_nil(stored.signal_id)
      assert is_nil(stored.fired_at)
      refute Scheduled.produced_signal?(external)
      assert inspect(stored.last_fire_error) =~ "signal_producer_conflict"
    end

    test "real cron and checkback fires retain proof through their generated Signal" do
      %{cron: cron, checkback: checkback} = real_schedule_fires()

      assert Scheduled.produced_signal?(cron.signal)
      assert Scheduled.produced_signal?(checkback.signal)

      for result <- [cron, checkback] do
        assert result.scheduled_event.signal_id == result.signal.id
        assert Scheduled.produced_signal?(Repo.get!(Signal, result.signal.id))
      end
    end

    test "external event types and copied schedule facts do not claim a scheduled run" do
      %{cron: cron, checkback: checkback} = real_schedule_fires()

      for result <- [cron, checkback], data <- [result.signal.data, false, ["external"]] do
        {:ok, external} =
          Repo.transact(fn repo ->
            Ankole.Signals.accept_in_tx(repo, %{
              source: result.signal.source,
              id: Ecto.UUID.generate(),
              type: result.signal.type,
              subject: result.signal.subject,
              data: data,
              target: %{
                agent_uid: result.signal.agent_uid,
                session_id: result.signal.session_id
              },
              authorization: Ankole.Principals.WorkAccess.service()
            })
          end)

        refute Scheduled.produced_signal?(external)
      end

      refute Scheduled.produced_signal?(%Signal{producer: :kernel})
      refute Scheduled.produced_signal?(%{type: "cron.fire"})
    end

    test "proof cannot move to another Agent, session, kind, status or tenant", %{tenant: tenant} do
      %{cron: %{signal: signal, scheduled_event: event}} = real_schedule_fires()
      %{principal: another_agent} = Ankole.PrincipalsFixtures.agent_fixture()

      refute Scheduled.produced_signal?(%{signal | agent_uid: another_agent.uid})
      refute Scheduled.produced_signal?(%{signal | session_id: "another-session"})
      refute Scheduled.produced_signal?(%{signal | type: "check_back_later.wakeup"})

      for status <- [:scheduled, :cancelled, :failed] do
        Repo.get!(ScheduledEvent, event.id)
        |> AshPostgres.DataLayer.to_ecto()
        |> Ecto.Changeset.change(%{status: status})
        |> Repo.update!()

        refute Scheduled.produced_signal?(signal)
      end

      Repo.get!(ScheduledEvent, event.id)
      |> AshPostgres.DataLayer.to_ecto()
      |> Ecto.Changeset.change(%{status: :fired, fired_at: nil})
      |> Repo.update!()

      refute Scheduled.produced_signal?(signal)

      Repo.get!(ScheduledEvent, event.id)
      |> AshPostgres.DataLayer.to_ecto()
      |> Ecto.Changeset.change(%{status: :fired, fired_at: @base_time})
      |> Repo.update!()

      assert Scheduled.produced_signal?(signal)

      other_tenant = create_tenant()
      Repo.put_tenant_id(other_tenant.id)
      refute Scheduled.produced_signal?(signal)
      Repo.put_tenant_id(tenant.id)
      assert Scheduled.produced_signal?(signal)
    end
  end

  describe "consecutive identical cron replies" do
    test "counts the streak across digits, URLs, and whitespace variance" do
      %{agent: agent, session_id: session_id} = cron_session()

      fire_with_reply(agent.uid, session_id, "monitor", """
      ⚠️ 监控仍被飞书权限错误 **230027** 阻断，无法读取 07:05–07:20 的群消息。
      [查看本次排查信息](https://open.feishu.cn/search?log_id=111&code=230027)
      """)

      fire_with_reply(agent.uid, session_id, "monitor", """
      ⚠️ 监控仍被飞书权限错误 **230027** 阻断，无法读取 08:05–08:20 的群消息。
      [查看本次排查信息](https://open.feishu.cn/search?log_id=222&code=230027)
      """)

      fire_with_reply(agent.uid, session_id, "monitor", """
      ⚠️ 监控仍被飞书权限错误 **230027** 阻断，无法读取   09:05–09:20 的群消息。
      [查看本次排查信息](https://open.feishu.cn/search?log_id=333&code=230027)
      """)

      input = cron_fire_event(agent.uid, session_id, "monitor")

      assert Scheduled.consecutive_identical_replies(input) == 3

      opts = Scheduled.opts(input, [])
      assert opts[:request_context]["consecutive_identical_replies"] == 3
    end

    test "stops the streak at the first different reply" do
      %{agent: agent, session_id: session_id} = cron_session()

      fire_with_reply(agent.uid, session_id, "monitor", "工作簿已更新，本轮读取 12 条消息。")
      fire_with_reply(agent.uid, session_id, "monitor", "⚠️ 监控失败：权限错误 230027。")
      fire_with_reply(agent.uid, session_id, "monitor", "⚠️ 监控失败：权限错误 230027。")

      input = cron_fire_event(agent.uid, session_id, "monitor")

      assert Scheduled.consecutive_identical_replies(input) == 2
    end

    test "one prior reply is not a streak and adds no context field" do
      %{agent: agent, session_id: session_id} = cron_session()

      fire_with_reply(agent.uid, session_id, "monitor", "⚠️ 监控失败：权限错误 230027。")

      input = cron_fire_event(agent.uid, session_id, "monitor")

      assert Scheduled.consecutive_identical_replies(input) == 1

      opts = Scheduled.opts(input, [])
      refute Map.has_key?(opts[:request_context], "consecutive_identical_replies")
    end

    test "a silent previous fire breaks the streak" do
      %{agent: agent, session_id: session_id} = cron_session()

      fire_with_reply(agent.uid, session_id, "monitor", "⚠️ 监控失败：权限错误 230027。")
      cron_fire_event(agent.uid, session_id, "monitor")

      input = cron_fire_event(agent.uid, session_id, "monitor")

      assert Scheduled.consecutive_identical_replies(input) == 0
    end

    test "other schedules and other sessions stay out of the streak" do
      %{agent: agent, session_id: session_id} = cron_session()
      stub_driver(%{agent_uid: agent.uid, session_id: "other-session"})

      fire_with_reply(agent.uid, session_id, "other-schedule", "⚠️ 监控失败：权限错误 230027。")
      fire_with_reply(agent.uid, "other-session", "monitor", "⚠️ 监控失败：权限错误 230027。")
      fire_with_reply(agent.uid, session_id, "monitor", "⚠️ 监控失败：权限错误 230027。")
      fire_with_reply(agent.uid, session_id, "monitor", "⚠️ 监控失败：权限错误 230027。")

      input = cron_fire_event(agent.uid, session_id, "monitor")

      assert Scheduled.consecutive_identical_replies(input) == 2
    end

    test "a checkback wakeup never reports a streak" do
      %{agent: agent, session_id: session_id} = cron_session()

      {:ok, input} =
        Ankole.Signals.accept(%{
          producer: :kernel,
          target: %{agent_uid: agent.uid, session_id: session_id},
          source: "test:runtime",
          reply_route: %{binding_name: "control-plane:test"},
          id: "checkback-#{System.unique_integer([:positive])}",
          data: %{"wake_payload" => %{"quiet_success" => false}},
          type: "check_back_later.wakeup",
          available_at: @base_time,
          authorization: Ankole.Principals.WorkAccess.service()
        })

      assert Scheduled.consecutive_identical_replies(input) == 0
    end
  end

  test "five-fire batch reads preserve Message precedence, nil fallback and every Intent status" do
    %{agent: agent, session_id: session_id} = cron_session()
    room = Ankole.ExternalConversationsFixtures.external_conversation_fixture("mock:streak")
    events = for _ <- 1..5, do: cron_fire_event(agent.uid, session_id, "batch")
    [first, second, third, fourth, fifth] = events

    for {event, text, status, age} <- [
          {first, "wrong fallback", :sent, 1},
          {second, "same report 2", :failed, 2},
          {third, "same report 3", :sent, 3},
          {fourth, "old wrong fallback", :sent, 4},
          {fourth, "same report 4", :pending, 5},
          {fourth, nil, :sent, 6},
          {fifth, "same report 5", :failed, 7}
        ] do
      Ankole.SignalsFixtures.delivery_fixture!(%{
        agent_uid: agent.uid,
        binding_name: "control-plane:test",
        outbound_key: Ecto.UUID.generate(),
        operation: :reply,
        status: status,
        source_signal_id: event.id,
        fallback_visible_text: text,
        idempotency_key: Ecto.UUID.generate(),
        inserted_at: DateTime.add(@base_time, age, :second)
      })
    end

    for {event, text, seq} <- [
          {first, "same report 1", 1},
          {second, "old wrong message", 2},
          {second, nil, 3},
          {third, "", 4}
        ] do
      assert {:ok, _} =
               Repo.transact(fn _repo ->
                 Ankole.Ash.create(Ankole.Conversations.Message, :record, %{
                   id: Ecto.UUID.generate(),
                   conversation_id: room.id,
                   seq: seq,
                   author_type: :agent,
                   author_uid: agent.uid,
                   text: text,
                   signal_id: event.id,
                   origin: :external,
                   session_id: event.session_id,
                   created_at: DateTime.add(@base_time, seq, :second)
                 })
               end)
    end

    candidates = Ankole.Conversations.reply_candidate_texts(Enum.map(events, & &1.id))

    assert candidates == %{
             first.id => "same report 1",
             second.id => "same report 2",
             third.id => "",
             fourth.id => "same report 4",
             fifth.id => "same report 5"
           }

    # Copied external fire metadata cannot enter the producer-filtered window.
    external = cron_fire_event(agent.uid, session_id, "batch")

    external
    |> AshPostgres.DataLayer.to_ecto()
    |> Ecto.Changeset.change(%{producer: :external})
    |> Repo.update!()

    input = cron_fire_event(agent.uid, session_id, "batch")
    tag = make_ref()
    handler = {__MODULE__, tag}

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, metadata, {pid, tag} ->
          if self() == pid, do: send(pid, {tag, metadata.query})
        end,
        {self(), tag}
      )

    try do
      assert Scheduled.consecutive_identical_replies(input) == 2
    after
      :telemetry.detach(handler)
    end

    reads = collect_reads(tag)
    assert length(reads) == 3
    assert Enum.all?(reads, &String.starts_with?(&1, "SELECT"))

    # A missing most recent reply is not removed from the fire sequence.
    next = cron_fire_event(agent.uid, session_id, "batch")
    assert Scheduled.consecutive_identical_replies(next) == 0
    assert Ankole.Conversations.reply_candidate_texts([]) == %{}
  end

  test "identical replies scan at most five fires" do
    %{agent: agent, session_id: session_id} = cron_session()
    for n <- 1..7, do: fire_with_reply(agent.uid, session_id, "bounded", "same report #{n}")
    input = cron_fire_event(agent.uid, session_id, "bounded")
    assert Scheduled.consecutive_identical_replies(input) == 5
  end

  defp collect_reads(tag, acc \\ []) do
    receive do
      {^tag, query} -> collect_reads(tag, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp cron_session do
    %{principal: agent} = agent_fixture()
    session_id = "session-#{System.unique_integer([:positive])}"
    stub_driver(%{agent_uid: agent.uid, session_id: session_id})
    %{agent: agent, session_id: session_id}
  end

  defp real_schedule_fires do
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()

    %{principal: agent} =
      Ankole.PrincipalsFixtures.agent_fixture(%{owner_principal_uid: human.uid})

    {:ok, detail} =
      Ankole.ConversationsFixtures.create(human.uid, %{
        conversation_id: Ecto.UUID.generate(),
        message_id: Ecto.UUID.generate(),
        agent_uid: agent.uid,
        text: "Check for changes"
      })

    source = Ankole.WorkFixtures.service_source(agent.uid)
    session_id = Ankole.Sessions.Key.conversation(detail.conversation.id)
    due_at = DateTime.add(@base_time, 5, :minute)

    {:ok, %{scheduled_event: checkback}} =
      Ankole.Schedule.create_check_back_later(
        %{
          source_signal_id: source.id,
          agent_uid: agent.uid,
          session_id: session_id,
          tool_call_id: "check-correlation",
          idempotency_key: Ecto.UUID.generate(),
          schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "UTC"},
          reason: "Check for changes later",
          check: "Report changes",
          reply_route: %{"conversation_id" => detail.conversation.id}
        },
        now: @base_time
      )

    {:ok, checkback_fire} = Ankole.Schedule.fire_due_event(checkback.id, now: due_at)

    {:ok, %{cron_schedule: cron}} =
      Ankole.Schedule.create_cron_schedule(
        %{
          agent_uid: agent.uid,
          owner_session_id: session_id,
          name: "Producer correlation",
          idempotency_key: Ecto.UUID.generate(),
          schedule: %{
            "kind" => "every",
            "every_ms" => 60_000,
            "anchor_at" => DateTime.to_iso8601(@base_time),
            "timezone" => "UTC"
          },
          payload: %{"task" => "Report changes"},
          delivery: %{"targets" => [%{"conversation_id" => detail.conversation.id}]}
        },
        now: @base_time,
        created_by: %{"signal_id" => source.id}
      )

    {:ok, cron_fire} = Ankole.Schedule.fire_cron(cron.id, now: cron.next_fire_at)
    %{cron: cron_fire, checkback: checkback_fire}
  end

  defp cron_fire_event(agent_uid, session_id, schedule_name) do
    {:ok, event} =
      Ankole.Signals.accept(%{
        producer: :kernel,
        target: %{agent_uid: agent_uid, session_id: session_id},
        source: "test:runtime",
        reply_route: %{binding_name: "control-plane:test"},
        id: "cron-fire-#{System.unique_integer([:positive])}",
        data: %{
          "wake_payload" => %{"cron_schedule_name" => schedule_name}
        },
        type: "cron.fire",
        available_at: @base_time,
        authorization: Ankole.Principals.WorkAccess.service()
      })

    event
  end

  defp fire_with_reply(agent_uid, session_id, schedule_name, reply_text) do
    event = cron_fire_event(agent_uid, session_id, schedule_name)

    Ankole.SignalsFixtures.delivery_fixture!(%{
      agent_uid: agent_uid,
      binding_name: "control-plane:test",
      outbound_key: "reply-#{System.unique_integer([:positive])}",
      operation: :reply,
      status: :sent,
      source_signal_id: event.id,
      fallback_visible_text: reply_text,
      idempotency_key: "idem-#{System.unique_integer([:positive])}"
    })

    event
  end
end
