defmodule Ankole.Brain.AcceptanceTest do
  @moduledoc """
  Integration tests for the BrainV3 acceptance criteria that run without a
  model provider: decay ordering, purge TTL, consolidation idempotency, and
  slice watermark idempotency.
  """

  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures
  import Ecto.Query

  alias Ankole.Brain.Claims
  alias Ankole.Brain.Dreaming
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Recall
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.ConversationsLearning
  alias Ankole.Brain.Sources
  alias Ankole.Ecto.UUIDv7

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])
    %{principal: human} = human_fixture()

    {:ok, object} =
      Objects.create_object(
        %{slug: "companies/decay", type: "company", title: "Decay Co"},
        human.uid
      )

    %{human: human, object: object}
  end

  describe "acceptance 11: fact decay" do
    test "effective confidence decays with age and never rewrites storage", %{human: human} do
      now = DateTime.utc_now(:microsecond)
      old = DateTime.add(now, -21 * 86_400, :second)

      {:ok, %{claim: fresh}} =
        Claims.write_fact(
          %{
            object_slug: "companies/decay",
            claim: "Fresh event happened yesterday",
            kind: "event",
            holder: "world",
            audience_scope: "world",
            notability: "medium",
            confidence: 0.8,
            valid_from: now,
            provenance: "test"
          },
          human.uid
        )

      {:ok, %{claim: stale}} =
        Claims.write_fact(
          %{
            object_slug: "companies/decay",
            claim: "Stale event happened three weeks ago",
            kind: "event",
            holder: "world",
            audience_scope: "world",
            notability: "medium",
            confidence: 0.8,
            valid_from: old,
            provenance: "test"
          },
          human.uid
        )

      forgetting = Ankole.Brain.Config.forgetting()

      fresh_effective = Recall.effective_confidence(fresh, forgetting, now)
      stale_effective = Recall.effective_confidence(stale, forgetting, now)

      # Event halflife is 7 days; the design formula is exp(-age/halflife),
      # so 21 days decays by exp(-3).
      assert_in_delta fresh_effective, 0.8, 0.01
      assert_in_delta stale_effective, 0.8 * :math.exp(-3), 0.001

      # Storage never changes.
      assert Repo.get!(Claim, stale.id).confidence == 0.8

      # Expiry ends the current state regardless of decay.
      {:ok, expired} = Claims.expire_fact(stale.id)
      assert Recall.effective_confidence(expired, forgetting, now) == 0.0
    end
  end

  describe "acceptance 12: purge" do
    test "hard-deletes only soft-deleted objects past the TTL", %{human: human} do
      {:ok, _fresh_deleted} =
        Objects.create_object(
          %{slug: "notes/fresh-deleted", type: "note", title: "Fresh"},
          human.uid
        )

      {:ok, _old_deleted} =
        Objects.create_object(
          %{slug: "notes/old-deleted", type: "note", title: "Old"},
          human.uid
        )

      {:ok, _fresh} = Objects.soft_delete("notes/fresh-deleted")
      {:ok, old} = Objects.soft_delete("notes/old-deleted")

      # Age the second deletion past the 72h TTL.
      old
      |> Ecto.Changeset.change(
        deleted_at: DateTime.add(DateTime.utc_now(:microsecond), -80 * 3600, :second)
      )
      |> Repo.update!()

      # An expired fact must survive purge forever.
      {:ok, %{claim: fact}} =
        Claims.write_fact(
          %{
            object_slug: "companies/decay",
            claim: "A fact that expires but never purges",
            kind: "fact",
            holder: "world",
            audience_scope: "world",
            notability: "low",
            confidence: 0.6,
            valid_from: DateTime.utc_now(:microsecond),
            provenance: "test"
          },
          human.uid
        )

      {:ok, _expired} = Claims.expire_fact(fact.id)

      report = Dreaming.phase_purge()
      assert report.purged == 1

      assert Repo.get_by(Object, slug: "notes/fresh-deleted")
      refute Repo.get_by(Object, slug: "notes/old-deleted")
      assert Repo.get(Claim, fact.id)
    end
  end

  describe "acceptance 13/14: consolidation" do
    test "clusters same-bucket facts into one brain take and reruns idempotently", %{
      human: human,
      object: object
    } do
      base_vector = fn seed ->
        # Nearly identical vectors cluster; the orthogonal one stays out.
        List.duplicate(0.0, 4096)
        |> List.replace_at(0, 1.0)
        |> List.replace_at(1, seed)
        |> Pgvector.new()
      end

      old = DateTime.add(DateTime.utc_now(:microsecond), -2 * 86_400, :second)

      insert_fact = fn text, scope, vector ->
        Repo.insert!(%Claim{
          id: UUIDv7.autogenerate(),
          claim_type: "fact",
          object_slug: object.slug,
          claim: text,
          kind: "preference",
          holder: "people/#{human.uid}",
          audience_scope: scope,
          notability: "medium",
          confidence: 0.8,
          valid_from: old,
          created_at: old,
          provenance: "test",
          embedding: vector,
          embedding_signature: "sig",
          embedded_at: old
        })
      end

      insert_fact.("Likes salmon sashimi", "world", base_vector.(0.01))
      insert_fact.("Likes tuna sashimi", "world", base_vector.(0.02))
      insert_fact.("Likes eel sashimi", "world", base_vector.(0.03))

      # Same bucket key but different scope must not cluster with the world
      # bucket: it stays below the bucket minimum on its own.
      insert_fact.(
        "Private note about sashimi budget",
        "principal:#{human.uid}",
        base_vector.(0.04)
      )

      report = Dreaming.phase_consolidate()
      assert report.promoted == 1

      takes =
        Claim
        |> where([claim], claim.claim_type == "take" and claim.holder == "brain")
        |> Repo.all()

      assert [take] = takes
      assert take.audience_scope == "world"
      assert take.object_slug == object.slug
      assert_in_delta take.weight, 0.8, 0.001

      consolidated =
        Claim
        |> where([claim], not is_nil(claim.consolidated_into))
        |> Repo.all()

      assert length(consolidated) == 3
      assert Enum.all?(consolidated, &(&1.consolidated_into == take.id))

      # A rerun promotes nothing new.
      rerun = Dreaming.phase_consolidate()
      assert rerun.promoted == 0

      takes_after =
        Claim
        |> where([claim], claim.claim_type == "take" and claim.holder == "brain")
        |> Repo.aggregate(:count)

      assert takes_after == 1
    end

    test "does not combine vectors from different embedding signatures", %{
      human: human,
      object: object
    } do
      vector = Pgvector.new([1.0 | List.duplicate(0.0, 4095)])
      old = DateTime.add(DateTime.utc_now(:microsecond), -2 * 86_400, :second)

      for {text, signature} <- [
            {"Signature A fact one", "model-a"},
            {"Signature A fact two", "model-a"},
            {"Signature B fact one", "model-b"}
          ] do
        Repo.insert!(%Claim{
          id: UUIDv7.autogenerate(),
          claim_type: "fact",
          object_slug: object.slug,
          claim: text,
          kind: "preference",
          holder: "people/#{human.uid}",
          audience_scope: "world",
          notability: "medium",
          confidence: 0.8,
          valid_from: old,
          created_at: old,
          provenance: "test",
          embedding: vector,
          embedding_signature: signature,
          embedded_at: old
        })
      end

      assert %{buckets: 0, promoted: 0} = Dreaming.phase_consolidate()
    end

    test "does not consolidate facts on a soft-deleted object", %{
      human: human,
      object: object
    } do
      vector = Pgvector.new([1.0 | List.duplicate(0.0, 4095)])
      old = DateTime.add(DateTime.utc_now(:microsecond), -2 * 86_400, :second)

      for index <- 1..3 do
        Repo.insert!(%Claim{
          id: UUIDv7.autogenerate(),
          claim_type: "fact",
          object_slug: object.slug,
          claim: "Forgotten consolidation fact #{index}",
          kind: "preference",
          holder: "people/#{human.uid}",
          audience_scope: "world",
          notability: "medium",
          confidence: 0.8,
          valid_from: old,
          created_at: old,
          provenance: "test",
          embedding: vector,
          embedding_signature: "model-a",
          embedded_at: old
        })
      end

      assert {:ok, _object} = Objects.soft_delete(object.slug)
      assert %{buckets: 0, promoted: 0} = Dreaming.phase_consolidate()
    end
  end

  describe "acceptance 2: slice watermarks" do
    test "version tokens identify processed slices and allow safe reruns" do
      channel = insert_channel!()

      insert_entry!(channel.id, "m1", "第一条消息", ~U[2026-08-20 10:00:00.000000Z])
      insert_entry!(channel.id, "m2", "第二条消息", ~U[2026-08-20 10:01:00.000000Z])

      slice = ConversationsLearning.pending_slice(channel.id)
      assert length(slice) == 2

      token = ConversationsLearning.slice_version_token(channel.id, slice)
      assert ConversationsLearning.slice_version_token(channel.id, slice) == token

      last = List.last(slice)

      {:ok, source} =
        Sources.get_or_create(%{
          kind: "conversation",
          upstream_id: channel.id,
          name: channel.id
        })

      :ok =
        Sources.record_extraction_watermark(
          Repo,
          source,
          {last.message.created_at, last.message.seq}
        )

      # The watermark moves: the same entries never re-enter a slice.
      assert ConversationsLearning.pending_slice(channel.id) == []

      # A new message forms the next slice with a new token.
      insert_entry!(channel.id, "m3", "第三条消息", ~U[2026-08-20 11:00:00.000000Z])
      next_slice = ConversationsLearning.pending_slice(channel.id)
      assert Enum.map(next_slice, & &1.external_ref.provider_message_id) == ["m3"]

      next_token = ConversationsLearning.slice_version_token(channel.id, next_slice)
      refute next_token == token
    end

    test "the watermark keeps entries that share the boundary arrival instant" do
      channel = insert_channel!()
      shared_at = ~U[2026-08-20 10:00:00.000000Z]

      # A bulk mirror insert gives every entry one arrival instant. A
      # timestamp-only strict comparison would lose everything after the
      # covered entry; the (first_seen_at, provider_message_id) order keeps it.
      insert_entry!(channel.id, "m1", "第一条", shared_at)
      insert_entry!(channel.id, "m2", "第二条", shared_at)
      insert_entry!(channel.id, "m3", "第三条", shared_at)

      {:ok, source} =
        Sources.get_or_create(%{
          kind: "conversation",
          upstream_id: channel.id,
          name: channel.id
        })

      :ok = Sources.record_extraction_watermark(Repo, source, {shared_at, 2})

      assert Enum.map(
               ConversationsLearning.pending_slice(channel.id),
               & &1.external_ref.provider_message_id
             ) == ["m3"]
    end

    test "a late delivery with an old provider timestamp still enters the next slice" do
      channel = insert_channel!()

      insert_entry!(channel.id, "m1", "第一条", ~U[2026-08-20 10:00:00.000000Z])

      {:ok, source} =
        Sources.get_or_create(%{
          kind: "conversation",
          upstream_id: channel.id,
          name: channel.id
        })

      :ok =
        Sources.record_extraction_watermark(Repo, source, {~U[2026-08-20 10:00:00.000000Z], 1})

      # The provider sent this message before the watermark instant, but it
      # arrived after: the watermark compares arrival order only, so the
      # entry must not be skipped.
      insert_entry!(
        channel.id,
        "m2",
        "迟到的消息",
        ~U[2026-08-20 10:05:00.000000Z],
        provider_time: ~U[2026-08-20 09:59:00.000000Z]
      )

      assert Enum.map(
               ConversationsLearning.pending_slice(channel.id),
               & &1.external_ref.provider_message_id
             ) == ["m2"]
    end
  end

  describe "source archive fence" do
    test "an archived signal channel source stops learning before extraction" do
      allow_cache_database_access()
      Ankole.AppConfigure.Cache.clear_for_test()
      on_exit(fn -> Ankole.AppConfigure.Cache.clear_for_test() end)

      # The model is configured but must never be called: the archived gate
      # sits before the slice reaches extraction.
      %{principal: maintainer} =
        agent_fixture(%{
          options: %{
            "ai_agent" => %{
              "models" => %{
                "light" => %{"provider_id" => "brain-extract", "model" => "fake-extract"}
              }
            }
          }
        })

      {:ok, _value} =
        Ankole.AppConfigure.put_global_by_key("brain.maintainer_agent_uid", maintainer.uid)

      {:ok, group} =
        Ankole.AuthZ.create_principal_group(%{
          name: "fence-#{System.unique_integer([:positive])}",
          display_name: "Fence",
          domain: :operator,
          kind: :static
        })

      channel = insert_channel!(%{principal_group_id: group.id})
      insert_entry!(channel.id, "m1", "有长期价值的消息", ~U[2026-08-20 10:00:00.000000Z])

      # Registration is idempotent on (kind, upstream_id), so a pre-inserted
      # archived row is what the run reads back.
      Repo.insert!(%Ankole.Brain.Schemas.Source{
        id: UUIDv7.autogenerate(),
        upstream_id: channel.id,
        kind: "conversation",
        name: "archived channel",
        archived_at: DateTime.utc_now(:microsecond)
      })

      assert {:ok, %{status: :skipped, reason: :source_archived}} =
               ConversationsLearning.process_conversation(channel.id)

      # No terminal and no claims: the slice stays untouched.
      assert ConversationsLearning.pending_slice(channel.id) != []
      refute Repo.exists?(Claim |> where([claim], claim.conversation_id == ^channel.id))
    end
  end

  describe "dreaming phase 3" do
    test "model-free links advance separately from model timelines", %{
      object: object,
      human: human
    } do
      {:ok, target} =
        Objects.create_object(%{slug: "notes/target", type: "note", title: "Target"}, human.uid)

      {:ok, _} = Ankole.Brain.Links.add_alias(target.slug, "Target mention")

      {:ok, object} =
        Objects.update_object(
          object.slug,
          %{
            body: "[[notes/target]] and Target mention",
            expected_content_hash: object.content_hash
          },
          human.uid
        )

      assert Ankole.Brain.SelfHealing.reconcile_body_links() >= 1
      current = Repo.get_by!(Object, slug: object.slug)
      assert current.links_extracted_at == object.updated_at
      assert current.updated_at == object.updated_at
      assert current.timelines_extracted_at == nil
      assert Ankole.Brain.SelfHealing.reconcile_body_links() == 0

      links =
        Repo.all(from l in Ankole.Brain.Schemas.Link, where: l.from_object_slug == ^object.slug)

      assert Enum.sort(Enum.map(links, & &1.link_source)) == ["markdown", "mentions"]

      assert {:ok, _} = Ankole.Brain.Links.reconcile_object_links(object.slug)

      assert MapSet.new(links, & &1.id) ==
               MapSet.new(
                 Repo.all(
                   from l in Ankole.Brain.Schemas.Link, where: l.from_object_slug == ^object.slug
                 ),
                 & &1.id
               )

      assert %{status: :skipped, reason: :dreaming_model_not_configured} =
               Dreaming.phase_extract_timelines()

      assert Repo.get_by!(Object, slug: object.slug).timelines_extracted_at == nil

      {:ok, _} =
        Ankole.Brain.Links.upsert_link(%{
          from_object_slug: object.slug,
          to_object_slug: target.slug,
          link_type: "manual relation",
          link_source: "manual"
        })

      {:ok, object} =
        Objects.update_object(
          object.slug,
          %{body: "No references now.", expected_content_hash: object.content_hash},
          human.uid
        )

      assert DateTime.compare(object.updated_at, current.links_extracted_at) == :gt
      assert Ankole.Brain.SelfHealing.reconcile_body_links() >= 1

      assert [%{link_source: "manual"}] =
               Repo.all(
                 from l in Ankole.Brain.Schemas.Link, where: l.from_object_slug == ^object.slug
               )
    end
  end

  defp insert_channel!(attrs \\ %{}) do
    now = DateTime.utc_now(:microsecond)
    kind = attrs[:kind] || :im_group

    Repo.insert!(
      Ankole.Conversations.Conversation.changeset(
        %Ankole.Conversations.Conversation{},
        Map.merge(Map.drop(attrs, [:kind]), %{
          id: Ecto.UUID.generate(),
          kind: :external,
          external_kind: kind,
          provider_conversation_id: "test:acceptance-#{System.unique_integer([:positive])}",
          title: "Conversation",
          reply_mode: :entry,
          last_activity_at: now,
          first_seen_at: now,
          last_seen_at: now
        })
      )
    )
  end

  defp insert_entry!(conversation_id, provider_message_id, text, seen_at, opts \\ []) do
    {:ok, result} =
      Repo.transact(
        &Ankole.Conversations.External.observe_in_tx(
          &1,
          conversation_id,
          %{
            provider_message_id: provider_message_id,
            text: text,
            author: %{"display_name" => "tester"},
            provider_time: Keyword.get(opts, :provider_time) || seen_at
          },
          seen_at
        )
      )

    result
  end
end
