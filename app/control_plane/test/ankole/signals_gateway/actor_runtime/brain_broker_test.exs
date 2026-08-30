defmodule Ankole.SignalsGateway.ActorRuntime.BrainBrokerTest do
  # The broker payloads must Torque-encode on the RPC wire. Brain read paths
  # return DateTime and Date values in many nested shapes, so every handler
  # result is asserted encodable here; a calendar struct that leaks through
  # fails these tests exactly the way it fails the live RPC.
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Brain.Claims
  alias Ankole.Brain.LibraryKnowledge
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.AIAgent.Library
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.BrainBroker
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef

  @ctx %{route: "test-route", request_id: "test-request"}

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])

    %{principal: owner} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: owner.uid})

    {:ok, object} =
      Objects.create_object(
        %{
          slug: "concepts/wire-format",
          type: "concept",
          title: "Wire Format",
          body: "Notes about the wire format."
        },
        agent.uid
      )

    {:ok, %{claim: _fact}} =
      Claims.write_fact(
        %{
          object_slug: object.slug,
          claim: "The wire format carries dated facts",
          kind: "fact",
          holder: "world",
          audience_scope: "world",
          notability: "medium",
          confidence: 0.9,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "test"
        },
        agent.uid
      )

    {:ok, _alias} = Ankole.Brain.Links.add_alias(object.slug, "Wire Format")

    turn_ref = %TurnRef{
      agent_uid: agent.uid,
      session_id: "session-#{System.unique_integer([:positive])}",
      activation_uid: "activation-#{System.unique_integer([:positive])}",
      actor_epoch: 1,
      actor_event_id: nil,
      revision: 0
    }

    %{agent: agent, object: object, turn_ref: turn_ref}
  end

  test "get_page returns an encodable payload for a page with dated facts", context do
    request = brain_request(%{"reference" => context.object.slug})

    assert {:ok, %{"page" => page}} =
             BrainBroker.handle_get_page(context.turn_ref, request, @ctx)

    assert page["slug"] == context.object.slug
    assert {:ok, _json} = Torque.encode(page)
  end

  test "context_pack injects at conversation start and again after a compaction checkpoint",
       context do
    conversation = insert_conversation!(context.agent.uid, context.turn_ref.session_id)
    request = brain_request(%{"participant_uids" => [], "recent_text" => "Wire Format"})

    # First turn of a fresh conversation: the slot is empty, the pack carries
    # the entity mentioned in the recent text, and it must Torque-encode.
    assert {:ok, pack} = BrainBroker.handle_context_pack(context.turn_ref, request, @ctx)
    assert {:ok, _json} = Torque.encode(pack)
    assert [entity | _rest] = pack["entities"]
    assert entity["slug"] == context.object.slug

    # Later turns of the same conversation get an empty pack.
    assert {:ok, skipped} = BrainBroker.handle_context_pack(context.turn_ref, request, @ctx)
    assert skipped == %{"entities" => [], "open_threads" => []}

    # A compaction checkpoint newer than the recorded slot reopens it once.
    insert_checkpoint!(context.agent.uid, conversation.id)

    assert {:ok, reinjected} =
             BrainBroker.handle_context_pack(context.turn_ref, request, @ctx)

    assert [_entity | _rest] = reinjected["entities"]

    assert {:ok, skipped_again} =
             BrainBroker.handle_context_pack(context.turn_ref, request, @ctx)

    assert skipped_again == %{"entities" => [], "open_threads" => []}
  end

  test "context_pack without a conversation row stays empty", context do
    request = brain_request(%{"participant_uids" => [], "recent_text" => "Wire Format"})

    assert {:ok, pack} = BrainBroker.handle_context_pack(context.turn_ref, request, @ctx)
    assert pack == %{"entities" => [], "open_threads" => []}
  end

  test "context_pack reopens for a retry of the same actor event", context do
    insert_conversation!(context.agent.uid, context.turn_ref.session_id)
    request = brain_request(%{"participant_uids" => [], "recent_text" => "Wire Format"})
    original = %{context.turn_ref | actor_event_id: Ankole.Ecto.UUIDv7.autogenerate()}

    assert {:ok, first} = BrainBroker.handle_context_pack(original, request, @ctx)
    assert [_entity | _rest] = first["entities"]

    assert {:ok, retried} = BrainBroker.handle_context_pack(original, request, @ctx)
    assert [_entity | _rest] = retried["entities"]

    successor = %{original | actor_event_id: Ankole.Ecto.UUIDv7.autogenerate()}
    assert {:ok, skipped} = BrainBroker.handle_context_pack(successor, request, @ctx)
    assert skipped == %{"entities" => [], "open_threads" => []}
  end

  test "volunteer pointers name the pages the message names, and nothing else", context do
    named = brain_request(%{"message_text" => "how did the Wire Format land?"})

    assert {:ok, %{"pointers" => [pointer]}} =
             BrainBroker.handle_volunteer_pointers(context.turn_ref, named, @ctx)

    assert pointer["slug"] == context.object.slug

    # The page is recent and salient, and this message still has no reason
    # to see it: an unasked pointer on every Turn teaches the model to skip
    # the block.
    touch_salience!(context.object)
    unrelated = brain_request(%{"message_text" => "please book a room for Thursday"})

    assert {:ok, %{"pointers" => []}} =
             BrainBroker.handle_volunteer_pointers(context.turn_ref, unrelated, @ctx)
  end

  test "recall returns an encodable payload with dated claims", context do
    request = brain_request(%{"query" => "wire format dated facts"})

    assert {:ok, result} = BrainBroker.handle_recall(context.turn_ref, request, @ctx)
    assert {:ok, _json} = Torque.encode(result)
    assert [claim | _rest] = result["claims"]
    assert is_binary(claim["valid_from"])
  end

  test "recall reports an unresolvable entity as a correctable payload", context do
    request = brain_request(%{"query" => "wire format", "entity" => "no-such-entity"})

    assert {:ok, %{"error" => "entity_not_found", "entity" => "no-such-entity"}} =
             BrainBroker.handle_recall(context.turn_ref, request, @ctx)
  end

  test "delta reports entity candidates on ambiguity", context do
    {:ok, _other} =
      Objects.create_object(
        %{slug: "concepts/wire-format-v2", type: "concept", title: "Wire Format V2"},
        context.agent.uid
      )

    {:ok, _alias} = Ankole.Brain.Links.add_alias("concepts/wire-format-v2", "Wire Format")

    request = brain_request(%{"entity" => "Wire Format"})

    assert {:ok, %{"error" => "ambiguous_entity", "candidates" => candidates}} =
             BrainBroker.handle_delta(context.turn_ref, request, @ctx)

    assert length(candidates) == 2
  end

  describe "remember" do
    test "applies the documented defaults and reports the fallback parent", context do
      request =
        brain_request(%{
          "claim" => "The querier prefers concise weekly summaries",
          "kind" => "preference",
          "scope" => "world",
          "provenance" => "test conversation"
        })

      assert {:ok, result} = BrainBroker.handle_remember(context.turn_ref, request, @ctx)
      # Channel-less session: the fallback parent is the agent's own page.
      assert result["object_slug"] == "agents/" <> context.agent.uid

      claim = Repo.get!(Ankole.Brain.Schemas.Claim, result["claim_id"])
      assert claim.confidence == 0.75
      assert claim.notability == "medium"
      assert claim.holder == "agents/" <> context.agent.uid

      take_request =
        brain_request(%{
          "claim" => "The wire format will change again this quarter",
          "kind" => "hunch",
          "scope" => "world",
          "provenance" => "test conversation"
        })

      assert {:ok, take_result} =
               BrainBroker.handle_remember(context.turn_ref, take_request, @ctx)

      take = Repo.get!(Ankole.Brain.Schemas.Claim, take_result["claim_id"])
      assert take.weight == 0.6
    end

    test "accepts until_date on takes and rejects it on facts", context do
      dated_take =
        brain_request(%{
          "claim" => "The share price closes above 40 CNY",
          "kind" => "bet",
          "scope" => "world",
          "provenance" => "deep research job 1234",
          "until_date" => "2026-09-30"
        })

      assert {:ok, result} = BrainBroker.handle_remember(context.turn_ref, dated_take, @ctx)

      take = Repo.get!(Ankole.Brain.Schemas.Claim, result["claim_id"])
      assert take.until_date == "2026-09-30"

      invalid_date =
        brain_request(%{
          "claim" => "The share price closes above 40 CNY",
          "kind" => "bet",
          "scope" => "world",
          "provenance" => "deep research job 1234",
          "until_date" => "end of Q3"
        })

      assert {:error, error} =
               BrainBroker.handle_remember(context.turn_ref, invalid_date, @ctx)

      assert error["message"] =~ "invalid_until_date"

      dated_fact =
        brain_request(%{
          "claim" => "The office moved to Building 5",
          "kind" => "fact",
          "scope" => "world",
          "provenance" => "test conversation",
          "until_date" => "2026-09-30"
        })

      assert {:error, error} =
               BrainBroker.handle_remember(context.turn_ref, dated_fact, @ctx)

      assert error["message"] =~ "until_date_only_for_takes"
    end

    test "attaches to a natural-language entity name and falls back on a miss", context do
      request =
        brain_request(%{
          "claim" => "Wire format work continues",
          "kind" => "fact",
          "scope" => "world",
          "entity" => "Wire Format",
          "provenance" => "test"
        })

      assert {:ok, result} = BrainBroker.handle_remember(context.turn_ref, request, @ctx)
      assert result["object_slug"] == context.object.slug

      miss =
        brain_request(%{
          "claim" => "Unattached memory line",
          "kind" => "fact",
          "scope" => "world",
          "entity" => "Nothing With This Name",
          "provenance" => "test"
        })

      assert {:ok, fallback} = BrainBroker.handle_remember(context.turn_ref, miss, @ctx)
      assert fallback["object_slug"] == "agents/" <> context.agent.uid
    end

    test "does not resolve a disabled lazy Skill as the memory parent", context do
      lazy_set = %{
        kind: :lazy_skills,
        set_id: "remember-lazy-visibility",
        name: "Remember lazy visibility",
        skills: [
          %{
            name: "idea-lineage",
            description: "Trace an idea evolution from stored lineage evidence.",
            metadata: %{"tags" => ["hidden-lineage-route"]},
            source_hash: "remember-visibility-v1",
            files: []
          }
        ]
      }

      assert {:ok, _report} = LibraryKnowledge.sync(sets: [lazy_set])
      assert {:ok, _sync} = Library.sync_agent_skills(context.agent.uid)

      assert {:ok, _skill} =
               Library.set_agent_skill_override(
                 context.agent.uid,
                 "brain:idea-lineage",
                 false
               )

      request =
        brain_request(%{
          "claim" => "An idea lineage trace needs stored lineage evidence",
          "kind" => "fact",
          "scope" => "world",
          "entity" => "hidden-lineage-route",
          "provenance" => "test"
        })

      assert {:ok, result} = BrainBroker.handle_remember(context.turn_ref, request, @ctx)
      assert result["object_slug"] == "agents/" <> context.agent.uid
    end

    test "a DM derives the asker's scope when scope is omitted", context do
      %{principal: asker} = human_fixture()
      channel = insert_channel!(:im_dm, nil)
      event = insert_actor_event!(context.agent.uid, asker.uid, channel.id)
      turn_ref = %{context.turn_ref | actor_event_id: event.id}

      request =
        brain_request(%{
          "claim" => "The asker prefers bronze status markers",
          "kind" => "preference",
          "provenance" => "private conversation"
        })

      assert {:ok, result} = BrainBroker.handle_remember(turn_ref, request, @ctx)
      assert result["audience_scope"] == "principal:" <> asker.uid
      assert result["signal_gateway_channel_id"] == channel.id
    end

    test "a group derives its member Group scope when the model omits scope", context do
      {:ok, group} =
        Ankole.AuthZ.create_principal_group(%{
          name: "remember-team-#{System.unique_integer([:positive])}",
          display_name: "Remember Team",
          domain: :operator,
          kind: :static
        })

      {:ok, _membership} = Ankole.AuthZ.add_principal_to_group(context.agent.uid, group.id)
      channel = insert_channel!(:im_group, group.id)
      event = insert_actor_event!(context.agent.uid, nil, channel.id)
      turn_ref = %{context.turn_ref | actor_event_id: event.id}

      request =
        brain_request(%{
          "claim" => "The team prefers bronze status markers",
          "kind" => "preference",
          "provenance" => "group conversation"
        })

      assert {:ok, result} = BrainBroker.handle_remember(turn_ref, request, @ctx)
      assert result["audience_scope"] == "group:" <> group.name
    end

    test "an explicit world scope is preserved in a DM", context do
      %{principal: asker} = human_fixture()
      channel = insert_channel!(:im_dm, nil)
      event = insert_actor_event!(context.agent.uid, asker.uid, channel.id)
      turn_ref = %{context.turn_ref | actor_event_id: event.id}

      request =
        brain_request(%{
          "claim" => "The all-hands meeting moves to 15:00 next Wednesday",
          "kind" => "event",
          "scope" => "world",
          "provenance" => "the asker said to share this with the whole company"
        })

      assert {:ok, result} = BrainBroker.handle_remember(turn_ref, request, @ctx)
      assert result["audience_scope"] == "world"
    end

    test "an explicit writable Group scope is preserved in a group conversation", context do
      {:ok, conversation_group} =
        Ankole.AuthZ.create_principal_group(%{
          name: "remember-channel-#{System.unique_integer([:positive])}",
          display_name: "Remember Channel",
          domain: :operator,
          kind: :static
        })

      {:ok, target_group} =
        Ankole.AuthZ.create_principal_group(%{
          name: "remember-target-#{System.unique_integer([:positive])}",
          display_name: "Remember Target",
          domain: :operator,
          kind: :static
        })

      for group <- [conversation_group, target_group] do
        {:ok, _membership} = Ankole.AuthZ.add_principal_to_group(context.agent.uid, group.id)
      end

      channel = insert_channel!(:im_group, conversation_group.id)
      event = insert_actor_event!(context.agent.uid, nil, channel.id)
      turn_ref = %{context.turn_ref | actor_event_id: event.id}

      request =
        brain_request(%{
          "claim" => "The target team uses bronze status markers",
          "kind" => "preference",
          "scope" => "group:" <> target_group.name,
          "provenance" => "group conversation"
        })

      assert {:ok, result} = BrainBroker.handle_remember(turn_ref, request, @ctx)
      assert result["audience_scope"] == "group:" <> target_group.name
    end

    test "an explicit scope that the Agent cannot write is rejected", context do
      {:ok, inaccessible_group} =
        Ankole.AuthZ.create_principal_group(%{
          name: "remember-inaccessible-#{System.unique_integer([:positive])}",
          display_name: "Remember Inaccessible",
          domain: :operator,
          kind: :static
        })

      request =
        brain_request(%{
          "claim" => "The inaccessible team uses bronze status markers",
          "kind" => "preference",
          "scope" => "group:" <> inaccessible_group.name,
          "provenance" => "test conversation"
        })

      assert {:error, payload} =
               BrainBroker.handle_remember(context.turn_ref, request, @ctx)

      assert payload["code"] == "writer_not_in_scope_group"
    end

    test "a group without a member Group rejects an omitted scope", context do
      channel = insert_channel!(:im_group, nil)
      event = insert_actor_event!(context.agent.uid, nil, channel.id)
      turn_ref = %{context.turn_ref | actor_event_id: event.id}

      request =
        brain_request(%{
          "claim" => "The team uses bronze status markers",
          "kind" => "preference",
          "provenance" => "group conversation"
        })

      assert {:error, payload} = BrainBroker.handle_remember(turn_ref, request, @ctx)
      assert payload["code"] == "im_group_without_member_group"
    end
  end

  describe "disclosure" do
    setup context do
      %{principal: asker} =
        human_fixture(%{uid: unique_uid("brain-disclosure-asker")})

      %{principal: bystander} =
        human_fixture(%{uid: unique_uid("brain-disclosure-bystander")})

      {:ok, group} =
        Ankole.AuthZ.create_principal_group(%{
          name: "disclosure-#{System.unique_integer([:positive])}",
          display_name: "Disclosure",
          domain: :operator,
          kind: :static
        })

      for uid <- [asker.uid, bystander.uid, context.agent.uid] do
        {:ok, _membership} = Ankole.AuthZ.add_principal_to_group(uid, group.id)
      end

      # A claim only the asker satisfies; the agent reaches it as its author.
      {:ok, %{claim: private_fact}} =
        Claims.write_fact(
          %{
            object_slug: context.object.slug,
            claim: "Wire format secret only for the asker",
            kind: "fact",
            holder: "world",
            audience_scope: "principal:" <> asker.uid,
            notability: "medium",
            confidence: 0.9,
            valid_from: DateTime.utc_now(:microsecond),
            provenance: "test"
          },
          context.agent.uid
        )

      %{
        asker: asker,
        bystander: bystander,
        group: group,
        private_fact: private_fact,
        group_channel: insert_channel!(:im_group, group.id),
        dm_channel: insert_channel!(:im_dm, nil)
      }
    end

    test "strict group chat holds back what a present member does not satisfy", context do
      event = insert_actor_event!(context.agent.uid, context.asker.uid, context.group_channel.id)
      turn_ref = %{context.turn_ref | actor_event_id: event.id}

      request = brain_request(%{"query" => "wire format secret"})
      assert {:ok, result} = BrainBroker.handle_recall(turn_ref, request, @ctx)
      refute context.private_fact.id in Enum.map(result["claims"], & &1["id"])
    end

    test "relaxed group chat checks only the asker", context do
      {:ok, _agent} =
        Ankole.Principals.update_agent(context.agent.uid, %{
          group_memory_disclosure_mode: :relaxed
        })

      event = insert_actor_event!(context.agent.uid, context.asker.uid, context.group_channel.id)
      turn_ref = %{context.turn_ref | actor_event_id: event.id}

      request = brain_request(%{"query" => "wire format secret"})
      assert {:ok, result} = BrainBroker.handle_recall(turn_ref, request, @ctx)
      assert context.private_fact.id in Enum.map(result["claims"], & &1["id"])
    end

    test "a private chat behaves the same under the strict default", context do
      event = insert_actor_event!(context.agent.uid, context.asker.uid, context.dm_channel.id)
      turn_ref = %{context.turn_ref | actor_event_id: event.id}

      request = brain_request(%{"query" => "wire format secret"})
      assert {:ok, result} = BrainBroker.handle_recall(turn_ref, request, @ctx)
      assert context.private_fact.id in Enum.map(result["claims"], & &1["id"])
    end

    # A cron fire and a check-back wakeup carry no sender and still deliver
    # into a channel, so the channel has to name the recipients: with none,
    # the Turn would speak whatever the Agent itself can reach.
    test "a scheduled private chat protects the reader it delivers to", context do
      insert_entry!(context.dm_channel.id, context.bystander.uid)
      event = insert_actor_event!(context.agent.uid, nil, context.dm_channel.id)
      turn_ref = %{context.turn_ref | actor_event_id: event.id}

      request = brain_request(%{"query" => "wire format secret"})
      assert {:ok, result} = BrainBroker.handle_recall(turn_ref, request, @ctx)
      refute context.private_fact.id in Enum.map(result["claims"], & &1["id"])
    end

    test "a scheduled private chat still serves its own reader", context do
      insert_entry!(context.dm_channel.id, context.asker.uid)
      event = insert_actor_event!(context.agent.uid, nil, context.dm_channel.id)
      turn_ref = %{context.turn_ref | actor_event_id: event.id}

      request = brain_request(%{"query" => "wire format secret"})
      assert {:ok, result} = BrainBroker.handle_recall(turn_ref, request, @ctx)
      assert context.private_fact.id in Enum.map(result["claims"], & &1["id"])
    end

    test "a scheduled group chat checks the members in relaxed mode too", context do
      {:ok, _agent} =
        Ankole.Principals.update_agent(context.agent.uid, %{
          group_memory_disclosure_mode: :relaxed
        })

      event = insert_actor_event!(context.agent.uid, nil, context.group_channel.id)
      turn_ref = %{context.turn_ref | actor_event_id: event.id}

      request = brain_request(%{"query" => "wire format secret"})
      assert {:ok, result} = BrainBroker.handle_recall(turn_ref, request, @ctx)
      refute context.private_fact.id in Enum.map(result["claims"], & &1["id"])
    end

    test "a scheduled group chat discloses nothing when its member group is unavailable",
         context do
      unresolved_channel = insert_channel!(:im_group, nil)
      event = insert_actor_event!(context.agent.uid, nil, unresolved_channel.id)
      turn_ref = %{context.turn_ref | actor_event_id: event.id}

      request = brain_request(%{"query" => "wire format secret"})
      assert {:ok, result} = BrainBroker.handle_recall(turn_ref, request, @ctx)
      refute context.private_fact.id in Enum.map(result["claims"], & &1["id"])
    end

    test "a strict group chat does not degrade to asker-only disclosure", context do
      unresolved_channel = insert_channel!(:im_group, nil)
      event = insert_actor_event!(context.agent.uid, context.asker.uid, unresolved_channel.id)
      turn_ref = %{context.turn_ref | actor_event_id: event.id}

      request = brain_request(%{"query" => "wire format secret"})
      assert {:ok, result} = BrainBroker.handle_recall(turn_ref, request, @ctx)
      refute context.private_fact.id in Enum.map(result["claims"], & &1["id"])
    end

    test "a scheduled reply checks every delivery target", context do
      insert_entry!(context.dm_channel.id, context.asker.uid)

      delivery = %{
        "targets" => [
          %{
            "binding_name" => "test-binding",
            "signal_channel_id" => context.dm_channel.id
          },
          %{
            "binding_name" => "second-binding",
            "signal_channel_id" => context.group_channel.id
          }
        ]
      }

      event =
        insert_actor_event!(context.agent.uid, nil, context.dm_channel.id, %{
          type: "cron.fire",
          payload: %{"data" => %{"wake_payload" => %{"delivery" => delivery}}}
        })

      turn_ref = %{context.turn_ref | actor_event_id: event.id}
      request = brain_request(%{"query" => "wire format secret"})

      assert {:ok, result} = BrainBroker.handle_recall(turn_ref, request, @ctx)
      refute context.private_fact.id in Enum.map(result["claims"], & &1["id"])
    end
  end

  test "the context pack carries what a participant holds in this channel", context do
    %{principal: speaker} = human_fixture()
    speaker_slug = "people/" <> speaker.uid
    channel = insert_channel!(:im_dm, nil)
    event = insert_actor_event!(context.agent.uid, speaker.uid, channel.id)
    turn_ref = %{context.turn_ref | actor_event_id: event.id}
    insert_conversation!(context.agent.uid, turn_ref.session_id)

    # A claim whose named entity does not resolve is filed on the channel,
    # so only the holder's own card can carry it back into a conversation.
    {:ok, %{claim: _channel_claim}} =
      Claims.write_fact(
        %{
          signal_gateway_channel_id: channel.id,
          claim: "Prefers a written summary before any call",
          kind: "preference",
          holder: speaker_slug,
          audience_scope: "world",
          notability: "high",
          confidence: 0.9,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "test"
        },
        context.agent.uid
      )

    request = brain_request(%{"participant_uids" => [speaker.uid], "recent_text" => ""})

    assert {:ok, pack} = BrainBroker.handle_context_pack(turn_ref, request, @ctx)
    assert [card] = pack["entities"]
    assert card["slug"] == speaker_slug
    assert Enum.any?(card["facts"], &(&1["claim"] =~ "written summary"))
  end

  describe "learn_source" do
    test "a channel-less turn defaults to the agent's own scope and enqueues the run",
         context do
      url = "https://example.com/paper-#{System.unique_integer([:positive])}"
      request = brain_request(%{"url" => url})

      assert {:ok, result} = BrainBroker.handle_learn_source(context.turn_ref, request, @ctx)
      assert result["status"] == "learning"
      assert result["audience_scope"] == "principal:" <> context.agent.uid

      source = Repo.get_by!(Ankole.Brain.Schemas.Source, kind: "url", upstream_id: url)
      assert source.default_audience_scope == "principal:" <> context.agent.uid

      assert [_job] =
               Repo.all(
                 from job in Oban.Job, where: job.worker == "Ankole.Brain.Jobs.LearnSource"
               )

      # The same url reuses the Source and re-runs learning.
      assert {:ok, again} = BrainBroker.handle_learn_source(context.turn_ref, request, @ctx)
      assert again["source_id"] == result["source_id"]

      assert [_only] =
               Repo.all(
                 from source in Ankole.Brain.Schemas.Source,
                   where: source.kind == "url" and source.upstream_id == ^url
               )
    end

    test "a DM turn defaults to the asker's principal scope", context do
      %{principal: asker} = human_fixture()
      dm = insert_channel!(:im_dm, nil)
      event = insert_actor_event!(context.agent.uid, asker.uid, dm.id)
      turn_ref = %{context.turn_ref | actor_event_id: event.id}

      url = "https://example.com/dm-#{System.unique_integer([:positive])}"

      assert {:ok, result} =
               BrainBroker.handle_learn_source(turn_ref, brain_request(%{"url" => url}), @ctx)

      assert result["audience_scope"] == "principal:" <> asker.uid
    end

    test "a member-backed group turn defaults to the group scope", context do
      {:ok, group} =
        Ankole.AuthZ.create_principal_group(%{
          name: "learn-team-#{System.unique_integer([:positive])}",
          display_name: "Learn Team",
          domain: :operator,
          kind: :static
        })

      {:ok, _membership} = Ankole.AuthZ.add_principal_to_group(context.agent.uid, group.id)
      channel = insert_channel!(:im_group, group.id)
      event = insert_actor_event!(context.agent.uid, nil, channel.id)
      turn_ref = %{context.turn_ref | actor_event_id: event.id}

      url = "https://example.com/group-#{System.unique_integer([:positive])}"

      assert {:ok, result} =
               BrainBroker.handle_learn_source(turn_ref, brain_request(%{"url" => url}), @ctx)

      assert result["audience_scope"] == "group:" <> group.name
    end

    test "a group without a member group names the blocker instead of guessing", context do
      channel = insert_channel!(:im_group, nil)
      event = insert_actor_event!(context.agent.uid, nil, channel.id)
      turn_ref = %{context.turn_ref | actor_event_id: event.id}

      url = "https://example.com/orphan-#{System.unique_integer([:positive])}"

      assert {:error, payload} =
               BrainBroker.handle_learn_source(turn_ref, brain_request(%{"url" => url}), @ctx)

      assert payload["code"] == "im_group_without_member_group"
    end

    test "an explicit world scope applies and a non-http url is refused", context do
      url = "https://example.com/world-#{System.unique_integer([:positive])}"

      assert {:ok, result} =
               BrainBroker.handle_learn_source(
                 context.turn_ref,
                 brain_request(%{"url" => url, "scope" => "world"}),
                 @ctx
               )

      assert result["audience_scope"] == "world"

      assert {:error, payload} =
               BrainBroker.handle_learn_source(
                 context.turn_ref,
                 brain_request(%{"url" => "ftp://example.com/file"}),
                 @ctx
               )

      assert payload["code"] == "invalid_url"
    end
  end

  defp insert_channel!(kind, principal_group_id) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(
      Ankole.SignalsGateway.Channel.changeset(%Ankole.SignalsGateway.Channel{}, %{
        id: "test:broker-#{System.unique_integer([:positive])}",
        kind: kind,
        reply_mode: :entry,
        principal_group_id: principal_group_id,
        metadata: %{},
        raw_payload: %{},
        first_seen_at: now,
        last_seen_at: now
      })
    )
  end

  # Recall touches a retrieved page; this is the state a page reaches after
  # it has been read recently and carries weight.
  defp touch_salience!(object) do
    object
    |> Ecto.Changeset.change(
      salience_touched_at: DateTime.utc_now(:microsecond),
      emotional_weight: 1.0
    )
    |> Repo.update!()
  end

  defp insert_entry!(channel_id, author_uid) do
    now = DateTime.utc_now(:microsecond)
    unique = System.unique_integer([:positive])

    Repo.insert!(
      Ankole.SignalsGateway.Entry.changeset(%Ankole.SignalsGateway.Entry{}, %{
        signal_channel_id: channel_id,
        source_entry_id: "entry-#{unique}",
        document_id: "signal-gateway-entry:test-#{unique}",
        text: "hello",
        author: %{"principal_uid" => author_uid},
        first_seen_at: now,
        last_seen_at: now
      })
    )
  end

  defp insert_actor_event!(agent_uid, sender_uid, channel_id, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          agent_uid: agent_uid,
          binding_name: "test-binding",
          session_id: "session-#{System.unique_integer([:positive])}",
          source_event_id: "event-#{System.unique_integer([:positive])}",
          signal_channel_id: channel_id,
          type: "signal",
          available_at: DateTime.utc_now(:microsecond),
          queue_sequence: System.unique_integer([:positive]),
          sender_key: sender_uid,
          payload: %{}
        },
        overrides
      )

    Repo.insert!(struct!(Ankole.SignalsGateway.ActorEvent, attrs))
  end

  defp brain_request(params) do
    %FabricProto.BrainRequest{params_json: Ankole.JSON.encode!(params)}
  end

  defp insert_conversation!(agent_uid, session_id) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(%Ankole.AIGateway.Schemas.Conversation{
      id: Ecto.UUID.generate(),
      subject_uid: agent_uid,
      conversation_key: session_id,
      metadata: %{},
      inserted_at: now,
      updated_at: now
    })
  end

  defp insert_checkpoint!(agent_uid, conversation_id) do
    # Strictly after the recorded slot timestamp, so the comparison is stable.
    at = DateTime.add(DateTime.utc_now(:microsecond), 1, :second)

    Repo.insert!(%Ankole.AIGateway.Schemas.Message{
      subject_uid: agent_uid,
      conversation_id: conversation_id,
      type: "checkpoint",
      status: "complete",
      content: [%{"id" => "cmp_#{Ecto.UUID.generate()}", "type" => "compaction_artifact"}],
      metadata: %{},
      inserted_at: at,
      updated_at: at
    })
  end
end
