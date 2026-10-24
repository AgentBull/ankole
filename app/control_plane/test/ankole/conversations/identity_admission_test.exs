defmodule Ankole.Conversations.IdentityAdmissionTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures

  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership
  alias Ankole.Principals
  alias Ankole.Principals.MappingRequest
  alias Ankole.Principals.MappingRequests
  alias Ankole.Conversations.Message
  alias Ankole.Conversations.InboundBatch
  alias Ankole.Conversations.Observe
  alias Ankole.Conversations.Delivery.Intent

  # Existing provider history uses the confirmed observation boundary. Raw
  # Principal authority is never accepted through the public adapter ingress.
  defp record_existing_entry!(agent_uid, entry) do
    assert {:ok, result} =
             Repo.transact(fn ->
               with {:ok, conversation} <-
                      Ankole.Conversations.External.observe_conversation_in_tx(
                        %{agent_uid: agent_uid},
                        %{
                          provider_conversation_id: entry.provider_conversation_id,
                          external_kind: entry.channel.kind,
                          reply_mode: entry.channel.reply_mode
                        },
                        base_time()
                      ) do
                 Ankole.Conversations.External.observe_in_tx(
                   conversation.id,
                   %{
                     provider_message_id: entry.provider_message_id,
                     provider_thread_id: Map.get(entry, :provider_thread_id),
                     text: entry.text,
                     author: Map.new(entry.author, fn {key, value} -> {to_string(key), value} end)
                   },
                   base_time()
                 )
               end
             end)

    result
  end

  defp dm_entry(author, overrides \\ %{}) do
    Map.merge(
      %{
        source_event_id: "evt-#{System.unique_integer([:positive])}",
        provider_conversation_id: "lark:chat:admission",
        provider_message_id: "msg-#{System.unique_integer([:positive])}",
        channel: %{kind: :im_dm, reply_mode: :entry, name: "DM"},
        text: "hello",
        author: author,
        provider_time: base_time()
      },
      overrides
    )
  end

  defp stranger_author(overrides \\ %{}) do
    Map.merge(
      %{
        id: "ou_stranger",
        platform_subject: "ou_stranger",
        display_name: "Stranger",
        metadata: %{"provider" => "lark-main"}
      },
      overrides
    )
  end

  test "provider authors cannot supply internal identity or work authority" do
    %{principal: agent} = agent_fixture()
    %{principal: human} = human_fixture()
    binding_fixture(agent.uid, "boundary", :ignore)

    for author <- [
          %{principal_uid: human.uid},
          %{"principal_uid" => human.uid, "platform_subject" => "forged"},
          %{agent_uid: agent.uid},
          %{"agent_uid" => agent.uid, "platform_subject" => "forged"},
          %{human_access_version: human.access_version, platform_subject: "forged"}
        ] do
      assert {:error, {:invalid_ingress_author_authority, _}} =
               Observe.emit_entry(agent.uid, "boundary", dm_entry(author))
    end

    assert {:error, {:invalid_ingress_attr_key, :sender_key}} =
             Observe.emit_entry(agent.uid, "boundary", dm_entry(%{}, %{sender_key: human.uid}))

    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(InboundBatch, :count) == 0
    assert Repo.aggregate(Ankole.Signals.Signal, :count) == 0
    assert {:error, :not_found} = Principals.resolve_platform_subject("boundary", "forged")
  end

  test "manual review holds an unmatched sender: one pending row, one notice per message" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "lark-adm", :ignore, unmatched_sender_policy: :manual_review)

    assert {:ok, %{status: :held_unmapped_sender}} =
             Observe.emit_entry(agent.uid, "lark-adm", dm_entry(stranger_author()))

    assert {:ok, %{status: :held_unmapped_sender}} =
             Observe.emit_entry(agent.uid, "lark-adm", dm_entry(stranger_author()))

    assert Repo.aggregate(Message, :count) == 0
    assert {:error, :not_found} = Principals.resolve_platform_subject("lark-main", "ou_stranger")

    assert [request] = Repo.all(MappingRequest)
    assert request.provider == "lark-main"
    assert request.external_id == "ou_stranger"
    assert request.display_name == "Stranger"

    notices = Repo.all(Intent)
    assert length(notices) == 2
    assert Enum.all?(notices, &(&1.operation == :reply))
    assert Enum.all?(notices, &(&1.fallback_visible_text =~ "Ankole Console"))
  end

  test "unaddressed group chatter from an unmatched sender is ignored entirely" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "lark-adm", :record_only, unmatched_sender_policy: :manual_review)

    entry =
      dm_entry(stranger_author(), %{
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"}
      })

    assert {:ok, %{status: :ignored_unmapped_sender}} =
             Observe.emit_entry(agent.uid, "lark-adm", entry)

    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(MappingRequest, :count) == 0
    assert Repo.aggregate(Intent, :count) == 0
  end

  test "ignored group messages keep their full reference data without admitting unmatched senders" do
    %{principal: agent} = agent_fixture()
    principal_count = Repo.aggregate(Principals.Principal, :count)
    membership_count = Repo.aggregate(Membership, :count)

    for policy <- [:create_standalone, :manual_review] do
      name = "b18-#{policy}"
      binding_fixture(agent.uid, name, :ignore, unmatched_sender_policy: policy)

      input =
        dm_entry(stranger_author(), %{
          channel: %{kind: :im_group, reply_mode: :entry},
          text: "Complete retained text",
          raw_payload: %{"provider" => "original", "nested" => [1, 2]}
        })

      assert {:ok, %{status: :ignored, inbound_batch: batch}} =
               Observe.emit_entry(agent.uid, name, input, now: base_time())

      assert [stored] = batch.entries
      assert stored["text"] == input.text
      assert stored["raw_payload"] == input.raw_payload
      assert stored["author"]["platform_subject"] == "ou_stranger"
      refute Map.has_key?(stored["author"], "principal_uid")

      assert {:error, :not_found} =
               Principals.resolve_platform_subject("lark-main", "ou_stranger")

      assert Repo.aggregate(Principals.Principal, :count) == principal_count
      assert Repo.aggregate(Membership, :count) == membership_count
      assert Repo.aggregate(MappingRequest, :count) == 0
      assert Repo.aggregate(Intent, :count) == 0
      assert Repo.aggregate(Message, :count) == 0

      assert {:ok, [%{status: :ignored}]} =
               finalize_due_inbound_batch_events(now: batch.available_at)

      assert Repo.get!(InboundBatch, batch.id).entries == batch.entries
    end
  end

  test "ignored known senders do not refresh identities or join signal-source groups" do
    %{principal: agent} = agent_fixture()
    %{principal: human, human_user: user} = human_fixture()
    binding_fixture(agent.uid, "b18-known", :ignore)
    membership_count = Repo.aggregate(Membership, :count)
    original = Repo.get!(Principals.Principal, human.uid)

    assert {:ok, %{status: :ignored}} =
             Observe.emit_entry(
               agent.uid,
               "b18-known",
               dm_entry(stranger_author(%{email: user.email}), %{
                 channel: %{kind: :im_group, reply_mode: :entry}
               })
             )

    Ankole.DataCase.assert_persisted_equal(Repo.get!(Principals.Principal, human.uid), original)
    assert {:error, :not_found} = Principals.resolve_platform_subject("lark-main", "ou_stranger")
    assert Repo.aggregate(Membership, :count) == membership_count
    refute Repo.get_by(Group, name: String.downcase("signal_source:#{agent.uid}:b18-known"))

    assert {:ok, %{identity: identity}} =
             Principals.upsert_platform_subject_human(%{
               provider: "lark-main",
               external_id: "ou_stranger",
               email: user.email,
               metadata: %{"source" => "b18-baseline"}
             })

    assert identity.principal_uid == human.uid
    original = Repo.get!(Principals.Principal, human.uid)

    assert {:ok, %{status: :ignored}} =
             Observe.emit_entry(
               agent.uid,
               "b18-known",
               dm_entry(stranger_author(), %{
                 channel: %{kind: :im_group, reply_mode: :entry}
               })
             )

    Ankole.DataCase.assert_persisted_equal(
      Repo.get!(Principals.ExternalIdentity, identity.id),
      identity
    )

    Ankole.DataCase.assert_persisted_equal(Repo.get!(Principals.Principal, human.uid), original)
    assert Repo.aggregate(Membership, :count) == membership_count
    refute Repo.get_by(Group, name: String.downcase("signal_source:#{agent.uid}:b18-known"))
  end

  test "replying to the Agent still requires real identity admission under ignore" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "b18-reply", :record_only, unmatched_sender_policy: :manual_review)

    target =
      dm_entry(%{agent_uid: agent.uid}, %{
        provider_message_id: "b18-agent-reply",
        channel: %{kind: :im_group, reply_mode: :entry},
        text: "Agent context"
      })

    record_existing_entry!(agent.uid, target)
    binding_fixture(agent.uid, "b18-reply", :ignore, unmatched_sender_policy: :manual_review)

    assert {:ok, %{status: :held_unmapped_sender}} =
             Observe.emit_entry(
               agent.uid,
               "b18-reply",
               dm_entry(stranger_author(), %{
                 channel: %{kind: :im_group, reply_mode: :entry},
                 reply_to_provider_message_id: target.provider_message_id
               })
             )

    assert [%MappingRequest{external_id: "ou_stranger"}] = Repo.all(MappingRequest)
    assert Repo.aggregate(InboundBatch, :count) == 0
    assert Repo.aggregate(Intent, :count) == 1
  end

  test "a reply in an Agent-participated thread still requires identity admission" do
    %{principal: agent} = agent_fixture()
    %{principal: human} = human_fixture()

    binding_fixture(agent.uid, "b18-thread", :record_only,
      unmatched_sender_policy: :manual_review
    )

    for {author, id} <- [
          {%{principal_uid: human.uid}, "b18-root"},
          {%{agent_uid: agent.uid}, "b18-agent"}
        ] do
      record_existing_entry!(
        agent.uid,
        dm_entry(author, %{
          provider_message_id: id,
          provider_thread_id: "b18-thread",
          channel: %{kind: :im_group, reply_mode: :entry}
        })
      )
    end

    binding_fixture(agent.uid, "b18-thread", :ignore, unmatched_sender_policy: :manual_review)

    assert {:ok, %{status: :held_unmapped_sender}} =
             Observe.emit_entry(
               agent.uid,
               "b18-thread",
               dm_entry(stranger_author(), %{
                 provider_thread_id: "b18-thread",
                 reply_to_provider_message_id: "b18-root",
                 channel: %{kind: :im_group, reply_mode: :entry}
               })
             )

    assert [%MappingRequest{external_id: "ou_stranger"}] = Repo.all(MappingRequest)
    assert Repo.aggregate(Intent, :count) == 1
  end

  test "a sender that matches an existing principal by email is admitted and bound" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "lark-adm", :ignore, unmatched_sender_policy: :manual_review)
    %{principal: human, human_user: human_user} = human_fixture()

    author = stranger_author(%{email: human_user.email})

    assert {:ok, %{status: :accepted}} =
             Observe.emit_entry(agent.uid, "lark-adm", dm_entry(author))

    assert {:ok, matched} = Principals.resolve_platform_subject("lark-main", "ou_stranger")
    assert matched.uid == human.uid
  end

  test "an external subject equal to a Principal UID never claims that Principal" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "lark-adm", :ignore, unmatched_sender_policy: :manual_review)
    binding_fixture(agent.uid, "lark-auto", :ignore, unmatched_sender_policy: :create_standalone)
    %{principal: human} = human_fixture()
    author = stranger_author(%{id: human.uid, platform_subject: human.uid})

    assert {:ok, %{status: :held_unmapped_sender}} =
             Observe.emit_entry(agent.uid, "lark-adm", dm_entry(author))

    assert [request] = Repo.all(MappingRequest)
    assert request.external_id == human.uid

    assert {:ok, %{status: :accepted}} =
             Observe.emit_entry(agent.uid, "lark-auto", dm_entry(author))

    assert {:ok, standalone} = Principals.resolve_platform_subject("lark-main", human.uid)
    refute standalone.uid == human.uid
    assert Repo.get!(Ankole.Principals.Principal, human.uid).display_name == human.display_name
  end

  test "binding a sender in one tenant neither admits nor clears the other tenant's pending sender" do
    tenant_a = Repo.tenant_id!()

    tenant_b =
      create_tenant(%{
        slug: "admission-" <> Ecto.UUID.generate(),
        display_name: "Other tenant"
      })

    %{principal: agent_a} = agent_fixture()
    %{principal: human_a} = human_fixture()
    binding_fixture(agent_a.uid, "lark-adm", :ignore, unmatched_sender_policy: :manual_review)

    assert {:ok, %{status: :held_unmapped_sender}} =
             Observe.emit_entry(agent_a.uid, "lark-adm", dm_entry(stranger_author()))

    [request_a] = Repo.all(MappingRequest)

    {agent_b, request_b} =
      Repo.with_tenant(tenant_b.id, fn ->
        %{principal: agent} = agent_fixture()
        binding_fixture(agent.uid, "lark-adm", :ignore, unmatched_sender_policy: :manual_review)

        assert {:ok, %{status: :held_unmapped_sender}} =
                 Observe.emit_entry(agent.uid, "lark-adm", dm_entry(stranger_author()))

        {agent, Repo.one!(MappingRequest)}
      end)

    assert Repo.tenant_id!() == tenant_a
    assert {:ok, _} = MappingRequests.bind_request(request_a.id, human_a.uid)

    assert {:ok, %{status: :accepted}} =
             Observe.emit_entry(agent_a.uid, "lark-adm", dm_entry(stranger_author()))

    assert Repo.aggregate(MappingRequest, :count) == 0

    Repo.with_tenant(tenant_b.id, fn ->
      assert Repo.get!(MappingRequest, request_b.id).external_id == "ou_stranger"

      assert {:error, :not_found} =
               Principals.resolve_platform_subject("lark-main", "ou_stranger")

      assert {:ok, %{status: :held_unmapped_sender}} =
               Observe.emit_entry(agent_b.uid, "lark-adm", dm_entry(stranger_author()))

      assert Repo.one!(MappingRequest).id == request_b.id
      assert Repo.aggregate(Message, :count) == 0
    end)
  end

  test "admitted senders accumulate in the binding's signal_source group" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "lark-adm", :ignore, unmatched_sender_policy: :create_standalone)

    assert {:ok, %{status: :accepted}} =
             Observe.emit_entry(agent.uid, "lark-adm", dm_entry(stranger_author()))

    group_name = String.downcase("signal_source:#{agent.uid}:lark-adm")
    group = Repo.get_by!(Group, name: group_name)
    assert group.domain == :signal_source
    assert group.kind == :static

    assert {:ok, principal} = Principals.resolve_platform_subject("lark-main", "ou_stranger")

    assert Repo.get_by(Membership, group_id: group.id, principal_uid: principal.uid)

    # A second message from the same sender does not duplicate anything.
    assert {:ok, %{status: :accepted}} =
             Observe.emit_entry(agent.uid, "lark-adm", dm_entry(stranger_author()))

    assert Repo.aggregate(Membership, :count) >= 1
    assert [_group] = Repo.all(from(group in Group, where: group.name == ^group_name))
  end

  test "a failed signal_source group write refuses the entry instead of admitting it" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "lark-adm", :ignore, unmatched_sender_policy: :create_standalone)

    # A same-named group in another domain makes the synced group write fail
    # with a domain mismatch, so the admission cannot complete.
    group_name = String.downcase("signal_source:#{agent.uid}:lark-adm")

    assert {:ok, _group} =
             Ankole.AuthZ.create_principal_group(%{
               name: group_name,
               display_name: "collision",
               domain: :operator,
               kind: :static,
               metadata: %{}
             })

    assert {:error, {:signal_source_group, _reason}} =
             Observe.emit_entry(agent.uid, "lark-adm", dm_entry(stranger_author()))

    assert Repo.aggregate(Message, :count) == 0
  end
end
