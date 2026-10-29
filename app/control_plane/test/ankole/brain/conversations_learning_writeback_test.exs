defmodule Ankole.Brain.ConversationsLearningWritebackTest do
  # The second write path: nobody called `remember`, and the conversation
  # still has to leave durable memory behind. This runs the real slice
  # extraction against a faked provider upstream, so what is asserted is
  # what the channel actually stores — holder, audience, and parent.
  use Ankole.AIGatewayCase

  import Ecto.Query

  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.ConversationsLearning
  alias Ankole.Brain.Sources
  alias Ankole.Repo

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])

    %{principal: owner} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: owner.uid})
    %{principal: alice} = human_fixture()

    test_pid = self()

    base_url =
      start_upstream_server(fn %{path: "chat/completions", body: body} ->
        send(test_pid, {:learning_request, body})

        items = %{
          "items" => [
            %{
              "type" => "fact",
              "claim" => "Alice wants a written summary before any call",
              "kind" => "preference",
              "holder" => "people/" <> alice.uid,
              # The model tries to widen a private source. The server must
              # clamp this value to the source audience.
              "scope" => "world",
              "notability" => "high",
              "confidence" => 0.75,
              "provenance" => "send me something written first"
            }
          ]
        }

        {:json, 200, chat_completion_body(body["model"], Ankole.JSON.encode!(items))}
      end)

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "brain-extract",
        provider_kind: "openrouter",
        base_url: base_url,
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
      })

    configure_brain_maintainer_profile!("light", "brain-extract", "fake-extract")

    channel = insert_channel!()
    insert_entry!(channel.id, "m1", "send me something written first", alice.uid)

    %{agent: agent, alice: alice, channel: channel}
  end

  test "the learning request includes installed relation vocabulary", %{channel: channel} do
    assert {:ok, %{status: :complete}} = ConversationsLearning.process_conversation(channel.id)
    assert_receive {:learning_request, request}
    prompt = Enum.map_join(request["messages"], "\n", & &1["content"])
    assert prompt =~ "Installed relation vocabulary:"
    assert prompt =~ "part_of (inverse has_part)"
    assert prompt =~ "Other labels"
  end

  test "idle slice discovery excludes completed channels and keeps the first new arrival",
       %{channel: channel, alice: alice} do
    alias Ankole.Conversations.Conversation, as: Channel
    alias Ankole.Conversations.Message, as: Entry
    old = DateTime.add(DateTime.utc_now(:microsecond), -3600, :second)
    Repo.update_all(from(c in Channel, where: c.id == ^channel.id), set: [last_activity_at: old])
    initial = get_entry!(channel.id, "m1")

    assert [%{conversation_id: id, first_seen_at: first}] =
             ConversationsLearning.idle_pending_slices()

    assert id == channel.id
    assert first == initial.created_at
    assert {:ok, %{status: :complete}} = ConversationsLearning.process_conversation(channel.id)
    assert Sources.conversation_extraction_watermark(channel.id) == initial.seq
    assert ConversationsLearning.idle_pending_slices() == []

    next = insert_entry!(channel.id, "m2", "One more message.", alice.uid)

    Repo.update_all(from(e in Entry, where: e.id == ^next.id),
      set: [created_at: initial.created_at]
    )

    Repo.update_all(from(c in Channel, where: c.id == ^channel.id), set: [last_activity_at: old])

    assert [%{conversation_id: ^id, first_seen_at: ^first}] =
             ConversationsLearning.idle_pending_slices()

    Repo.update_all(from(c in Channel, where: c.id == ^channel.id),
      set: [last_activity_at: DateTime.utc_now(:microsecond)]
    )

    assert ConversationsLearning.idle_pending_slices() == []
  end

  test "same-id channels keep their own pending entries and completion watermark",
       %{channel: channel} do
    alias Ankole.Conversations.Conversation, as: Channel
    alias Ankole.Conversations.Message, as: Entry
    old = DateTime.add(DateTime.utc_now(:microsecond), -3600, :second)
    Repo.update_all(from(c in Channel, where: c.id == ^channel.id), set: [last_activity_at: old])
    initial = get_entry!(channel.id, "m1")
    other = Ankole.DataCase.create_tenant()

    Repo.with_tenant(other.id, fn ->
      insert_channel!(%{id: channel.id, last_activity_at: old})
      # The first tenant's message must not supply this empty channel's slice.
      assert ConversationsLearning.idle_pending_slices() == []
    end)

    assert {:ok, %{status: :complete}} = ConversationsLearning.process_conversation(channel.id)
    assert ConversationsLearning.idle_pending_slices() == []

    Repo.with_tenant(other.id, fn ->
      %{principal: author} = human_fixture()
      entry = insert_entry!(channel.id, "m1", "The other team's pending message", author.uid)
      earlier = DateTime.add(initial.created_at, -60, :second)
      entry |> Ecto.Changeset.change(created_at: earlier) |> Repo.update!()

      Repo.update_all(from(c in Channel, where: c.id == ^channel.id),
        set: [last_activity_at: old]
      )

      # A later completion in the first tenant must not hide this message.
      assert [%{conversation_id: id, first_seen_at: ^earlier}] =
               ConversationsLearning.idle_pending_slices()

      assert id == channel.id
    end)

    assert ConversationsLearning.idle_pending_slices() == []
  end

  test "a slice from a moved Source watermark writes no memory", %{
    tenant: tenant,
    alice: alice,
    channel: channel
  } do
    entry =
      get_entry!(channel.id, "m1")

    base_url =
      start_upstream_server(fn %{path: "chat/completions", body: body} ->
        Repo.with_tenant(tenant.id, fn ->
          {:ok, source} =
            Sources.get_or_create(%{
              kind: "conversation",
              upstream_id: channel.id,
              name: channel.id
            })

          assert :ok =
                   Sources.record_extraction_watermark(
                     source,
                     {entry.created_at, entry.seq}
                   )
        end)

        output = Ankole.JSON.encode!(%{"items" => [valid_item(alice.uid)]})
        {:json, 200, chat_completion_body(body["model"], output)}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "brain-extract-watermark-race",
               provider_kind: "openrouter",
               base_url: base_url,
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
             })

    configure_brain_maintainer_profile!("light", "brain-extract-watermark-race", "fake-extract")

    assert {:error, :extraction_watermark_moved} =
             ConversationsLearning.process_conversation(channel.id)

    refute Repo.exists?(Claim |> where([claim], claim.conversation_id == ^channel.id))
    assert Sources.conversation_extraction_watermark(channel.id) == entry.seq
  end

  test "a private chat leaves the preference behind with its holder and audience",
       %{alice: alice, channel: channel} do
    assert {:ok, %{status: :complete, written: %{claims: 1}}} =
             ConversationsLearning.process_conversation(channel.id)

    assert [claim] =
             Claim
             |> where([claim], claim.conversation_id == ^channel.id)
             |> where([claim], claim.kind == "preference")
             |> Repo.all()

    assert claim.holder == "people/" <> alice.uid
    assert claim.audience_scope == "principal:" <> alice.uid
    # The entity never resolved, so the claim parents on the channel; the
    # participant's context-pack card is what carries it back.
    assert claim.object_slug == nil
  end

  test "a group chat cannot promote learned memory to world", %{
    agent: _agent,
    alice: alice
  } do
    {:ok, group} =
      Ankole.AuthZ.create_principal_group(%{
        name: "learning-team-#{System.unique_integer([:positive])}",
        display_name: "Learning Team",
        domain: :operator,
        kind: :static
      })

    channel = insert_channel!(%{kind: :im_group, principal_group_id: group.id})
    insert_entry!(channel.id, "g1", "send me something written first", alice.uid)

    assert {:ok, %{status: :complete, written: %{claims: 1}}} =
             ConversationsLearning.process_conversation(channel.id)

    assert [claim] =
             Claim
             |> where([claim], claim.conversation_id == ^channel.id)
             |> where([claim], claim.kind == "preference")
             |> Repo.all()

    assert claim.audience_scope == "group:#{group.name}"
  end

  test "an invalid or all-rejected extraction leaves the slice pending for a later retry", %{
    alice: alice,
    channel: channel
  } do
    {:ok, output_holder} = Agent.start_link(fn -> %{"unexpected" => []} end)

    base_url =
      start_upstream_server(fn %{path: "chat/completions", body: body} ->
        output = Agent.get(output_holder, & &1)

        {:json, 200, chat_completion_body(body["model"], Ankole.JSON.encode!(output))}
      end)

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "brain-extract-retry",
        provider_kind: "openrouter",
        base_url: base_url,
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
      })

    configure_brain_maintainer_profile!("light", "brain-extract-retry", "fake-extract")

    assert {:error, {:extraction_failed, :invalid_extraction_response}} =
             ConversationsLearning.process_conversation(channel.id)

    assert ConversationsLearning.has_pending_slice?(channel.id)
    refute Repo.exists?(Claim |> where([claim], claim.conversation_id == ^channel.id))

    Agent.update(output_holder, fn _output -> %{"items" => [invalid_item()]} end)

    assert {:error, {:all_items_rejected, [_reason | _rest]}} =
             ConversationsLearning.process_conversation(channel.id)

    assert ConversationsLearning.has_pending_slice?(channel.id)
    refute Repo.exists?(Claim |> where([claim], claim.conversation_id == ^channel.id))

    Agent.update(output_holder, fn _output -> %{"items" => [valid_item(alice.uid)]} end)

    assert {:ok, %{status: :complete, written: %{claims: 1}}} =
             ConversationsLearning.process_conversation(channel.id)

    refute ConversationsLearning.has_pending_slice?(channel.id)
  end

  test "editing an already learned message withdraws that Source and relearns the same sequence",
       c do
    assert {:ok, %{status: :complete}} = ConversationsLearning.process_conversation(c.channel.id)

    source =
      Repo.get_by!(Ankole.Brain.Schemas.Source, kind: "conversation", upstream_id: c.channel.id)

    old =
      Repo.one!(from claim in Claim, where: claim.provenance_session == ^("source:" <> source.id))

    message = get_entry!(c.channel.id, "m1")
    now = DateTime.add(message.created_at, 1, :second)

    observation = %{
      provider_message_id: "m1",
      text: "Send the revised written summary first.",
      provider_time: now,
      author: %{"principal_uid" => c.alice.uid}
    }

    assert {:ok, %{message: changed}} =
             Repo.transact(fn ->
               Ankole.Conversations.External.observe_in_tx(c.channel.id, observation, now)
             end)

    assert changed.seq == message.seq
    assert Sources.conversation_extraction_watermark(c.channel.id) == 0
    assert Repo.reload!(old).expired_at

    assert_enqueued(
      worker: Ankole.Brain.Jobs.ProcessConversationSlice,
      args: %{"conversation_id" => c.channel.id}
    )

    assert {:ok, %{status: :complete}} = ConversationsLearning.process_conversation(c.channel.id)

    current =
      Repo.one!(
        from claim in Claim,
          where:
            is_nil(claim.expired_at) and claim.provenance_session == ^("source:" <> source.id)
      )

    assert current.id != old.id

    assert {:ok, %{status: :unchanged}} =
             Repo.transact(fn ->
               Ankole.Conversations.External.observe_in_tx(c.channel.id, observation, now)
             end)

    assert Sources.conversation_extraction_watermark(c.channel.id) == message.seq
    assert is_nil(Repo.reload!(current).expired_at)

    assert {:ok, _} =
             Repo.transact(fn ->
               Ankole.Conversations.External.remove_in_tx(c.channel.id, "m1")
             end)

    assert Repo.reload!(current).expired_at

    assert {:ok, %{status: :skipped, reason: :im_dm_without_counterpart}} =
             ConversationsLearning.process_conversation(c.channel.id)
  end

  describe "existing page writeback" do
    setup %{alice: alice} do
      {:ok, _object} =
        Ankole.Brain.create_object(
          %{slug: "companies/acme", type: "company", title: "Acme Corporation"},
          :system
        )

      holder = "people/" <> alice.uid

      base_url =
        start_upstream_server(fn %{path: "chat/completions", body: body} ->
          items = [
            %{
              "type" => "fact",
              "claim" => "Acme wants to renew before the end of the quarter",
              "kind" => "commitment",
              "holder" => holder,
              "notability" => "high",
              "confidence" => 0.7,
              "object_slug" => "companies/acme",
              "provenance" => "renewal message"
            }
          ]

          body_text = Ankole.JSON.encode!(%{"items" => items})
          {:json, 200, chat_completion_body(body["model"], body_text)}
        end)

      {:ok, _provider} =
        ProviderConfigs.create_provider(%{
          provider_id: "brain-extract-dedup",
          provider_kind: "openrouter",
          base_url: base_url,
          credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
        })

      configure_brain_maintainer_profile!("light", "brain-extract-dedup", "fake-extract")

      :ok
    end

    test "an extracted claim links an existing page without creating a duplicate",
         %{agent: _agent, alice: alice} do
      channel = insert_channel!()

      insert_entry!(
        channel.id,
        "d1",
        "Acme wants to renew before the end of the quarter",
        alice.uid
      )

      assert {:ok, %{status: :complete, written: %{claims: 1, objects: 0}}} =
               ConversationsLearning.process_conversation(channel.id)

      assert [%{slug: "companies/acme"}] =
               Ankole.Brain.Schemas.Object
               |> where([object], like(object.slug, "companies/%"))
               |> Repo.all()

      assert [claim] = Claim |> where([claim], claim.kind == "commitment") |> Repo.all()
      assert claim.object_slug == "companies/acme"
      assert claim.holder == "people/" <> alice.uid
    end
  end

  defp insert_channel!(overrides \\ %{}) do
    now = DateTime.utc_now(:microsecond)

    overrides =
      case Map.pop(overrides, :kind) do
        {nil, attrs} -> attrs
        {kind, attrs} -> Map.put(attrs, :external_kind, kind)
      end

    Ankole.ExternalConversationsFixtures.create_external_conversation!(
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          external_kind: :im_dm,
          title: "Conversation",
          provider_conversation_id: "test:writeback-#{System.unique_integer([:positive])}",
          reply_mode: :entry,
          last_activity_at: now,
          first_seen_at: now,
          last_seen_at: now
        },
        overrides
      )
    )
  end

  defp invalid_item do
    %{
      "type" => "fact",
      "claim" => "This item must stay retryable",
      "kind" => "not-a-kind",
      "holder" => "world",
      "notability" => "medium",
      "confidence" => 0.75,
      "provenance" => "test"
    }
  end

  defp valid_item(holder_uid) do
    %{
      "type" => "fact",
      "claim" => "Alice wants a written summary before any call",
      "kind" => "preference",
      "holder" => "people/" <> holder_uid,
      "notability" => "high",
      "confidence" => 0.75,
      "provenance" => "send me something written first"
    }
  end

  defp insert_entry!(conversation_id, provider_message_id, text, author_uid) do
    now = DateTime.utc_now(:microsecond)

    {:ok, %{message: message}} =
      Repo.transact(fn ->
        Ankole.Conversations.External.observe_in_tx(
          conversation_id,
          %{
            provider_message_id: provider_message_id,
            text: text,
            author: %{"principal_uid" => author_uid, "display_name" => "Alice"},
            provider_time: now
          },
          now
        )
      end)

    message
  end

  defp get_entry!(conversation_id, provider_message_id) do
    %{message: message} =
      Ankole.Conversations.External.get_message(conversation_id, provider_message_id)

    message
  end
end
