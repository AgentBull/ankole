defmodule BullX.MailBoxTest do
  use BullX.DataCase, async: false

  alias BullX.AIAgent.{Conversations, Message}
  alias BullX.MailBox
  alias BullX.MailBox.{DeliveryRule, Entry}
  alias BullX.Principals
  alias BullX.Principals.Agent
  alias BullX.Repo

  setup do
    MailBox.rebuild_runtime()
    :ok
  end

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

  test "route reports cached-rule delivery failures instead of outer success" do
    original_config = Application.get_env(:bullx, MailBox, [])

    :ok =
      Application.put_env(
        :bullx,
        MailBox,
        Keyword.put(original_config, :active_rules_cache_ttl_ms, 60_000)
      )

    MailBox.invalidate_delivery_rule_cache()

    on_exit(fn ->
      Application.put_env(:bullx, MailBox, original_config)
      MailBox.invalidate_delivery_rule_cache()
    end)

    agent_uid = ai_agent!("stale-cached-rule")
    insert_delivery_rule!("stale cached rule", agent_uid, 100)

    assert {:ok, [_result]} = MailBox.route(cloud_event("stale-cache-warmup"))
    assert {1, _rows} = Repo.delete_all(from agent in Agent, where: agent.uid == ^agent_uid)

    assert {:error, {:delivery_failed, [{:error, :agent_not_found}]}} =
             MailBox.route(cloud_event("stale-cache-after-delete"))

    assert Repo.aggregate(Entry, :count) == 0
  end

  test "accepted pending entries are rebuilt from PG and deleted after processing" do
    agent_uid = ai_agent!("runtime-rebuild")

    assert {:ok, %{entry: %Entry{} = entry}} =
             MailBox.deliver(%{
               cloud_event: cloud_event("runtime-rebuild-1"),
               agent_uid: agent_uid,
               attention: :system,
               queue_key: "runtime-rebuild"
             })

    assert :ok = MailBox.rebuild_runtime()
    assert {:ok, 1} = MailBox.process_ready(1, async?: false)
    refute Repo.get(Entry, entry.id)
  end

  test "accepted-key ledger prevents duplicate delivery after the pending row is processed" do
    agent_uid = ai_agent!("dedupe")
    request = %{cloud_event: cloud_event("dedupe-1"), agent_uid: agent_uid, attention: :system}

    assert {:ok, %{entry: %Entry{} = entry}} = MailBox.deliver(request)

    assert {:ok, %{status: :duplicate, entry: %Entry{id: duplicate_id}}} =
             MailBox.deliver(request)

    assert duplicate_id == entry.id

    MailBox.force_ready()
    assert {:ok, 1} = MailBox.process_ready(1, async?: false)
    assert Repo.aggregate(Entry, :count) == 0

    assert {:ok, %{status: :duplicate, entry: nil}} = MailBox.deliver(request)
    assert Repo.aggregate(Entry, :count) == 0
  end

  test "lifecycle entries defer while their target receive entry is in flight" do
    agent_uid = ai_agent!("lifecycle-in-flight")

    assert {:ok, %{entry: receive_entry}} =
             MailBox.deliver(%{
               cloud_event:
                 message_event("receive-in-flight-1", "bullx.message.received", "om_1"),
               agent_uid: agent_uid,
               attention: :ambient,
               queue_key: "lifecycle-in-flight"
             })

    BullX.MailBox.Runtime.mark_in_flight([receive_entry], receive_entry.queue_key)
    lifecycle_entry = lifecycle_entry!(agent_uid, receive_entry.queue_key, "edit-in-flight-1")

    assert :ok = MailBox.process_entry(lifecycle_entry)
    assert %Entry{} = Repo.get!(Entry, lifecycle_entry.id)
  end

  test "lifecycle entries dispatch while their in-flight target receive entry is already materialized" do
    agent_uid = ai_agent!("lifecycle-materialized")

    assert {:ok, %{entry: receive_entry}} =
             MailBox.deliver(%{
               cloud_event:
                 message_event("receive-materialized-1", "bullx.message.received", "om_1"),
               agent_uid: agent_uid,
               attention: :ambient,
               queue_key: "lifecycle-materialized"
             })

    BullX.MailBox.Runtime.mark_in_flight([receive_entry], receive_entry.queue_key)

    assert {:ok, conversation} =
             Conversations.find_or_create_active(agent_uid, "lifecycle-materialized", %{})

    assert {:ok, _conversation, %Message{} = message} =
             Conversations.append_message(conversation, %{
               conversation_id: conversation.id,
               role: :im_ambient,
               kind: :normal,
               status: :complete,
               content: [%{"type" => "text", "text" => "before edit"}],
               mailbox_queue_key: receive_entry.queue_key,
               event_source: "bullx://test/mail-box",
               event_id: "receive-materialized-1",
               metadata: %{"provider_refs" => %{"message_ids" => ["om_1"]}}
             })

    lifecycle_entry =
      lifecycle_entry!(
        agent_uid,
        receive_entry.queue_key,
        "edit-materialized-1",
        "after edit"
      )

    assert :ok = MailBox.process_entry(lifecycle_entry)
    refute Repo.get(Entry, lifecycle_entry.id)

    assert %Message{content: [%{"type" => "text", "text" => "after edit"}]} =
             Repo.get!(Message, message.id)
  end

  test "coalesce pressure wakes a same-actor batch without touching PG timing fields" do
    agent_uid = ai_agent!("coalesce-pressure")
    queue_key = "coalesce-pressure-#{System.unique_integer([:positive])}"

    assert {:ok, %{entry: first}} =
             MailBox.deliver(%{
               cloud_event: coalesced_message_event("coalesce-pressure-1", "abcde", 10),
               agent_uid: agent_uid,
               attention: :ambient,
               queue_key: queue_key
             })

    assert {:ok, %{entry: second}} =
             MailBox.deliver(%{
               cloud_event: coalesced_message_event("coalesce-pressure-2", "fghij", 10),
               agent_uid: agent_uid,
               attention: :ambient,
               queue_key: queue_key
             })

    assert {:ok, 1} = MailBox.process_ready(1, async?: false)
    refute Repo.get(Entry, first.id)
    refute Repo.get(Entry, second.id)
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

  defp coalesced_message_event(id, text, max_chars) do
    id
    |> message_event("bullx.message.received", id, text)
    |> put_in(["data", "coalesce"], %{"window_ms" => 60_000, "max_chars" => max_chars})
  end

  defp lifecycle_entry!(agent_uid, queue_key, event_id, text \\ "after edit") do
    %Entry{}
    |> Entry.changeset(%{
      agent_uid: agent_uid,
      queue_key: queue_key,
      attention: :lifecycle,
      cloud_event: message_event(event_id, "bullx.message.edited", "om_1", text),
      idempotency_key: event_id
    })
    |> Repo.insert!()
  end
end
