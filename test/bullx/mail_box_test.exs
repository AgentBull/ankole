defmodule BullX.MailBoxTest do
  use BullX.DataCase, async: false

  alias BullX.AIAgent.{Conversations, Message}
  alias BullX.MailBox
  alias BullX.MailBox.{DeliveryRule, Entry}
  alias BullX.Principals
  alias BullX.Repo

  test "route fans out to every matching rule even when priorities are equal" do
    agent_a = ai_agent!("fanout-a")
    agent_b = ai_agent!("fanout-b")

    insert_delivery_rule!("fanout a", agent_a, 100)
    insert_delivery_rule!("fanout b", agent_b, 100)

    assert {:ok, results} = MailBox.route(cloud_event("fanout-1"))
    assert length(results) == 2
    assert Enum.all?(results, &match?({:ok, %{entry: %Entry{}}}, &1))

    entries = Repo.all(Entry)

    assert Enum.map(entries, & &1.agent_uid) |> Enum.sort() == [
             agent_a,
             agent_b
           ]
  end

  test "process_ready reclaims expired leased session entries" do
    agent_uid = ai_agent!("lease-sink")

    assert {:ok, %{entry: %Entry{} = entry}} =
             MailBox.deliver(%{
               cloud_event: cloud_event("lease-1"),
               agent_uid: agent_uid,
               attention: :system,
               session_key: "lease-test"
             })

    future = DateTime.add(DateTime.utc_now(:microsecond), 60, :second)

    Repo.update_all(
      from(mailbox_entry in Entry, where: mailbox_entry.id == ^entry.id),
      set: [status: :leased, lease_holder: "first", lease_expires_at: future]
    )

    assert {:ok, 0} = MailBox.process_ready(1, holder: "second", async?: false)

    past = DateTime.add(DateTime.utc_now(:microsecond), -1, :second)

    Repo.update_all(
      from(mailbox_entry in Entry, where: mailbox_entry.id == ^entry.id),
      set: [lease_expires_at: past]
    )

    assert {:ok, 1} = MailBox.process_ready(1, holder: "second", async?: false)
    assert %Entry{status: :processed, attempts: 1} = Repo.get!(Entry, entry.id)
  end

  test "lifecycle entries defer while their target receive entry is in flight" do
    agent_uid = ai_agent!("lifecycle-in-flight")

    assert {:ok, %{session: session, entry: receive_entry}} =
             MailBox.deliver(%{
               cloud_event:
                 message_event("receive-in-flight-1", "bullx.message.received", "om_1"),
               agent_uid: agent_uid,
               attention: :ambient,
               session_key: "lifecycle-in-flight",
               available_at: DateTime.add(DateTime.utc_now(:microsecond), 60, :second)
             })

    future = DateTime.add(DateTime.utc_now(:microsecond), 60, :second)

    Repo.update_all(
      from(entry in Entry, where: entry.id == ^receive_entry.id),
      set: [status: :leased, lease_holder: "receive-worker", lease_expires_at: future]
    )

    lifecycle_entry =
      %Entry{}
      |> Entry.changeset(%{
        agent_uid: agent_uid,
        mailbox_session_id: session.id,
        status: :leased,
        attention: :lifecycle,
        cloud_event: message_event("edit-in-flight-1", "bullx.message.edited", "om_1"),
        available_at: DateTime.utc_now(:microsecond),
        idempotency_key: "lifecycle-in-flight-edit",
        lease_holder: "lifecycle-worker",
        lease_expires_at: future,
        attempts: 1
      })
      |> Repo.insert!()

    assert :ok = MailBox.process_entry(lifecycle_entry, holder: "lifecycle-worker")

    assert %Entry{
             status: :pending,
             lease_holder: nil,
             lease_expires_at: nil,
             available_at: available_at
           } = Repo.get!(Entry, lifecycle_entry.id)

    assert DateTime.compare(available_at, DateTime.utc_now(:microsecond)) in [:gt, :eq]
  end

  test "lifecycle entries dispatch while their leased target receive entry is already materialized" do
    agent_uid = ai_agent!("lifecycle-materialized")

    assert {:ok, %{session: session, entry: receive_entry}} =
             MailBox.deliver(%{
               cloud_event:
                 message_event("receive-materialized-1", "bullx.message.received", "om_1"),
               agent_uid: agent_uid,
               attention: :ambient,
               session_key: "lifecycle-materialized",
               available_at: DateTime.add(DateTime.utc_now(:microsecond), 60, :second)
             })

    future = DateTime.add(DateTime.utc_now(:microsecond), 60, :second)

    Repo.update_all(
      from(entry in Entry, where: entry.id == ^receive_entry.id),
      set: [status: :leased, lease_holder: "receive-worker", lease_expires_at: future]
    )

    assert {:ok, conversation} =
             Conversations.find_or_create_active(agent_uid, "lifecycle-materialized", %{})

    assert {:ok, _conversation, %Message{} = message} =
             Conversations.append_message(conversation, %{
               conversation_id: conversation.id,
               role: :im_ambient,
               kind: :normal,
               status: :complete,
               content: [%{"type" => "text", "text" => "before edit"}],
               mailbox_session_id: session.id,
               mailbox_entry_id: receive_entry.id,
               event_source: "bullx://test/mail-box",
               event_id: "receive-materialized-1",
               metadata: %{"provider_refs" => %{"message_ids" => ["om_1"]}}
             })

    lifecycle_entry =
      %Entry{}
      |> Entry.changeset(%{
        agent_uid: agent_uid,
        mailbox_session_id: session.id,
        status: :leased,
        attention: :lifecycle,
        cloud_event:
          message_event("edit-materialized-1", "bullx.message.edited", "om_1", "after edit"),
        available_at: DateTime.utc_now(:microsecond),
        idempotency_key: "lifecycle-materialized-edit",
        lease_holder: "lifecycle-worker",
        lease_expires_at: future,
        attempts: 1
      })
      |> Repo.insert!()

    assert :ok = MailBox.process_entry(lifecycle_entry, holder: "lifecycle-worker")

    assert %Entry{status: :processed, lease_holder: nil, lease_expires_at: nil} =
             Repo.get!(Entry, lifecycle_entry.id)

    assert %Message{content: [%{"type" => "text", "text" => "after edit"}]} =
             Repo.get!(Message, message.id)
  end

  test "dispatcher wakes for delivered entries instead of waiting for idle poll" do
    start_supervised!({BullX.MailBox.Dispatcher, interval_ms: 10, claim_limit: 20})
    agent_uid = ai_agent!("wake-sink")

    assert {:ok, %{entry: %Entry{} = entry}} =
             MailBox.deliver(%{
               cloud_event: cloud_event("wake-1"),
               agent_uid: agent_uid,
               attention: :system,
               session_key: "wake-test",
               available_at: DateTime.add(DateTime.utc_now(:microsecond), 50, :millisecond)
             })

    assert_processed(entry.id)
  end

  test "next_ready_at normalizes mixed aggregate timestamp types" do
    agent_uid = ai_agent!("next-ready")
    future = DateTime.add(DateTime.utc_now(:microsecond), 60, :second)

    assert {:ok, _result} =
             MailBox.deliver(%{
               cloud_event: cloud_event("next-ready-pending"),
               agent_uid: agent_uid,
               attention: :system,
               session_key: "next-ready",
               available_at: future
             })

    assert {:ok, %{entry: %Entry{} = leased_entry}} =
             MailBox.deliver(%{
               cloud_event: cloud_event("next-ready-leased"),
               agent_uid: agent_uid,
               attention: :system,
               session_key: "next-ready",
               available_at: future
             })

    Repo.update_all(
      from(entry in Entry, where: entry.id == ^leased_entry.id),
      set: [status: :leased, lease_holder: "worker", lease_expires_at: nil]
    )

    assert %DateTime{} = MailBox.next_ready_at()
  end

  test "dispatcher stops scheduling itself when there is no pending work" do
    pid = start_supervised!({BullX.MailBox.Dispatcher, interval_ms: 10, claim_limit: 20})

    assert_idle_dispatcher(pid)
  end

  defp insert_delivery_rule!(name, agent_uid, priority) do
    %DeliveryRule{}
    |> DeliveryRule.changeset(%{
      name: name,
      active: true,
      priority: priority,
      match_expr: ~s(type == "bullx.test.mail"),
      agent_uid: agent_uid,
      metadata: %{}
    })
    |> Repo.insert!()
  end

  defp ai_agent!(uid) do
    {:ok, %{principal: principal}} =
      Principals.create_agent(%{
        principal: %{uid: "mailbox-agent-#{uid}", display_name: "Mailbox Agent #{uid}"},
        agent: %{
          profile: %{
            "ai_agent" => %{
              "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
              "mission" => "Handle mailbox tests."
            }
          }
        }
      })

    principal.uid
  end

  defp cloud_event(id) do
    %{
      "specversion" => "1.0",
      "id" => id,
      "source" => "bullx://test/mail-box",
      "type" => "bullx.test.mail",
      "time" => "2026-05-27T00:00:00Z",
      "datacontenttype" => "application/json",
      "data" => %{"reply_address" => %{"adapter" => "test", "channel_id" => "main"}}
    }
  end

  defp message_event(id, type, provider_message_id, text \\ "hello") do
    %{
      "specversion" => "1.0",
      "id" => id,
      "source" => "bullx://test/mail-box",
      "type" => type,
      "time" => "2026-05-27T00:00:00Z",
      "datacontenttype" => "application/json",
      "data" => %{
        "content" => [%{"type" => "text", "text" => text}],
        "channel" => %{"adapter" => "test", "id" => "main", "kind" => "group"},
        "scope" => %{"id" => "room_1", "thread_id" => nil},
        "actor" => %{"external_account_id" => "test:user", "display_name" => "User"},
        "refs" => [%{"kind" => "test.message", "id" => provider_message_id}],
        "raw_ref" => %{"message_id" => provider_message_id},
        "reply_address" => %{"adapter" => "test", "channel_id" => "main"},
        "routing_facts" => %{
          "attention_reason" => "unaddressed",
          "group_message_mode" => "engage_all"
        }
      }
    }
  end

  defp assert_processed(entry_id, attempts \\ 20)

  defp assert_processed(entry_id, attempts) when attempts > 0 do
    case Repo.get!(Entry, entry_id).status do
      :processed ->
        assert_sessions_released()

      _status ->
        Process.sleep(25)
        assert_processed(entry_id, attempts - 1)
    end
  end

  defp assert_processed(entry_id, 0) do
    status = Repo.get!(Entry, entry_id).status
    flunk("expected mailbox entry #{entry_id} to be processed, got: #{inspect(status)}")
  end

  defp assert_sessions_released(attempts \\ 20)

  defp assert_sessions_released(attempts) when attempts > 0 do
    leased_count =
      Repo.aggregate(
        from(session in BullX.MailBox.Session, where: not is_nil(session.lease_holder)),
        :count
      )

    case leased_count do
      0 ->
        :ok

      _count ->
        Process.sleep(25)
        assert_sessions_released(attempts - 1)
    end
  end

  defp assert_sessions_released(0), do: flunk("expected mailbox sessions to be released")

  defp assert_idle_dispatcher(pid, attempts \\ 20)

  defp assert_idle_dispatcher(pid, attempts) when attempts > 0 do
    case :sys.get_state(pid).timer_ref do
      nil ->
        :ok

      _timer_ref ->
        Process.sleep(25)
        assert_idle_dispatcher(pid, attempts - 1)
    end
  end

  defp assert_idle_dispatcher(pid, 0) do
    flunk(
      "expected mailbox dispatcher to stop scheduling itself, got: #{inspect(:sys.get_state(pid))}"
    )
  end
end
