defmodule Ankole.Brain.ToolsTest do
  # Every operation result must JSON-encode for the model. Brain read paths
  # return DateTime and Date values in many nested shapes, so the results are
  # asserted encodable here; a calendar struct that leaks through fails these
  # tests exactly the way it fails the live tool output.
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Brain.Claims
  alias Ankole.Brain.LibraryKnowledge
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Tools
  alias Ankole.AIAgent.Library
  alias Ankole.SignalsGateway.BrainContext

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

    {:ok, context} = BrainContext.build(agent.uid, nil)

    %{agent: agent, object: object, context: context}
  end

  test "the catalog declares every operation with a JSON schema", _context do
    specs = Tools.function_specs(Tools.operations())

    assert Enum.map(specs, & &1["name"]) == Tools.operations()

    for spec <- specs do
      assert spec["type"] == "function"
      assert is_binary(spec["description"]) and spec["description"] != ""
      assert spec["parameters"]["type"] == "object"
      assert spec["parameters"]["additionalProperties"] == false
    end

    assert Tools.function_specs(["get_page", "recall"]) |> Enum.map(& &1["name"]) ==
             ["recall", "get_page"]

    [remember] = Tools.function_specs(["remember"])
    assert remember["description"] =~ "agents/<uid> identifies a system Agent Principal"

    assert Tools.read_only?("recall")
    refute Tools.read_only?("remember")
    refute Tools.operation?("delete_everything")
  end

  test "get_page returns an encodable payload for a page with dated facts", context do
    assert {:ok, %{"page" => page}} =
             Tools.execute("get_page", %{"reference" => context.object.slug}, context.context)

    assert page["slug"] == context.object.slug
    assert {:ok, _json} = Torque.encode(page)
  end

  test "volunteer pointers name the pages the message names, and nothing else", context do
    assert [pointer] =
             Tools.volunteer_pointers(context.context, "how did the Wire Format land?")

    assert pointer.slug == context.object.slug

    # The page is recent and salient, and this message still has no reason
    # to see it: an unasked pointer on every Turn teaches the model to skip
    # the block.
    touch_salience!(context.object)

    assert [] = Tools.volunteer_pointers(context.context, "please book a room for Thursday")
  end

  test "recall returns an encodable payload with dated claims", context do
    assert {:ok, result} =
             Tools.execute("recall", %{"query" => "wire format dated facts"}, context.context)

    assert {:ok, _json} = Torque.encode(result)
    assert [claim | _rest] = result["claims"]
    assert is_binary(claim["valid_from"])
  end

  test "recall reports an unresolvable entity as a correctable payload", context do
    assert {:ok, %{"error" => "entity_not_found", "entity" => "no-such-entity"}} =
             Tools.execute(
               "recall",
               %{"query" => "wire format", "entity" => "no-such-entity"},
               context.context
             )
  end

  test "a result that names a lazy Skill record gets the loading hint", _context do
    assert Tools.lazy_skill_result?(%{"page" => %{"slug" => "lazyload-agent-skills/pdf"}})

    assert Tools.lazy_skill_result?(%{
             "claims" => [%{"object_slug" => "lazyload-agent-skills/x"}]
           })

    refute Tools.lazy_skill_result?(%{"page" => %{"slug" => "concepts/wire-format"}})
    assert Tools.lazy_skill_hint() =~ "skill_view"
  end

  test "delta reports entity candidates on ambiguity", context do
    {:ok, _other} =
      Objects.create_object(
        %{slug: "concepts/wire-format-v2", type: "concept", title: "Wire Format V2"},
        context.agent.uid
      )

    {:ok, _alias} = Ankole.Brain.Links.add_alias("concepts/wire-format-v2", "Wire Format")

    assert {:ok, %{"error" => "ambiguous_entity", "candidates" => candidates}} =
             Tools.execute("delta", %{"entity" => "Wire Format"}, context.context)

    assert length(candidates) == 2
  end

  test "an unknown operation and an unparseable window are refused", context do
    assert {:error, {:unknown_operation, "erase"}} =
             Tools.execute("erase", %{}, context.context)

    assert {:error, {:invalid_datetime, "since"}} =
             Tools.execute("delta", %{"since" => "last tuesday"}, context.context)
  end

  describe "remember" do
    test "applies the documented defaults and reports the fallback parent", context do
      assert {:ok, result} =
               Tools.execute(
                 "remember",
                 %{
                   "claim" => "The querier prefers concise weekly summaries",
                   "kind" => "preference",
                   "scope" => "world",
                   "provenance" => "test conversation"
                 },
                 context.context
               )

      # Channel-less request: the fallback parent is the agent's own page.
      assert result["object_slug"] == "agents/" <> context.agent.uid

      claim = Repo.get!(Ankole.Brain.Schemas.Claim, result["claim_id"])
      assert claim.confidence == 0.75
      assert claim.notability == "medium"
      assert claim.holder == "agents/" <> context.agent.uid

      assert {:ok, take_result} =
               Tools.execute(
                 "remember",
                 %{
                   "claim" => "The wire format will change again this quarter",
                   "kind" => "hunch",
                   "scope" => "world",
                   "provenance" => "test conversation"
                 },
                 context.context
               )

      take = Repo.get!(Ankole.Brain.Schemas.Claim, take_result["claim_id"])
      assert take.weight == 0.6
    end

    test "accepts until_date on takes and rejects it on facts", context do
      assert {:ok, result} =
               Tools.execute(
                 "remember",
                 %{
                   "claim" => "The share price closes above 40 CNY",
                   "kind" => "bet",
                   "scope" => "world",
                   "provenance" => "deep research job 1234",
                   "until_date" => "2026-09-30"
                 },
                 context.context
               )

      take = Repo.get!(Ankole.Brain.Schemas.Claim, result["claim_id"])
      assert take.until_date == "2026-09-30"

      assert {:error, :invalid_until_date} =
               Tools.execute(
                 "remember",
                 %{
                   "claim" => "The share price closes above 40 CNY",
                   "kind" => "bet",
                   "scope" => "world",
                   "provenance" => "deep research job 1234",
                   "until_date" => "end of Q3"
                 },
                 context.context
               )

      assert {:error, :until_date_only_for_takes} =
               Tools.execute(
                 "remember",
                 %{
                   "claim" => "The office moved to Building 5",
                   "kind" => "fact",
                   "scope" => "world",
                   "provenance" => "test conversation",
                   "until_date" => "2026-09-30"
                 },
                 context.context
               )
    end

    test "rejects an off-grid confidence and an unknown kind before writing", context do
      assert {:error, {:off_grid, "confidence"}} =
               Tools.execute(
                 "remember",
                 %{
                   "claim" => "Grid check",
                   "kind" => "fact",
                   "scope" => "world",
                   "confidence" => 0.77,
                   "provenance" => "test"
                 },
                 context.context
               )

      assert {:error, {:invalid_kind, "rumor"}} =
               Tools.execute(
                 "remember",
                 %{"claim" => "Kind check", "kind" => "rumor", "provenance" => "test"},
                 context.context
               )
    end

    test "attaches to a natural-language entity name and falls back on a miss", context do
      assert {:ok, result} =
               Tools.execute(
                 "remember",
                 %{
                   "claim" => "Wire format work continues",
                   "kind" => "fact",
                   "scope" => "world",
                   "entity" => "Wire Format",
                   "provenance" => "test"
                 },
                 context.context
               )

      assert result["object_slug"] == context.object.slug

      assert {:ok, fallback} =
               Tools.execute(
                 "remember",
                 %{
                   "claim" => "Unattached memory line",
                   "kind" => "fact",
                   "scope" => "world",
                   "entity" => "Nothing With This Name",
                   "provenance" => "test"
                 },
                 context.context
               )

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

      assert {:ok, result} =
               Tools.execute(
                 "remember",
                 %{
                   "claim" => "An idea lineage trace needs stored lineage evidence",
                   "kind" => "fact",
                   "scope" => "world",
                   "entity" => "hidden-lineage-route",
                   "provenance" => "test"
                 },
                 context.context
               )

      assert result["object_slug"] == "agents/" <> context.agent.uid
    end

    test "a DM derives the asker's scope when scope is omitted", context do
      %{principal: asker} = human_fixture()
      channel = insert_channel!(:im_dm, nil)
      event = insert_actor_event!(context.agent.uid, asker.uid, channel.id)
      turn_context = live_turn_context!(context.agent.uid, event)

      assert {:ok, result} =
               Tools.execute(
                 "remember",
                 %{
                   "claim" => "The asker prefers bronze status markers",
                   "kind" => "preference",
                   "provenance" => "private conversation"
                 },
                 turn_context
               )

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
      turn_context = live_turn_context!(context.agent.uid, event)

      assert {:ok, result} =
               Tools.execute(
                 "remember",
                 %{
                   "claim" => "The team prefers bronze status markers",
                   "kind" => "preference",
                   "provenance" => "group conversation"
                 },
                 turn_context
               )

      assert result["audience_scope"] == "group:" <> group.name
    end

    test "an explicit world scope is preserved in a DM", context do
      %{principal: asker} = human_fixture()
      channel = insert_channel!(:im_dm, nil)
      event = insert_actor_event!(context.agent.uid, asker.uid, channel.id)
      turn_context = live_turn_context!(context.agent.uid, event)

      assert {:ok, result} =
               Tools.execute(
                 "remember",
                 %{
                   "claim" => "The all-hands meeting moves to 15:00 next Wednesday",
                   "kind" => "event",
                   "scope" => "world",
                   "provenance" => "the asker said to share this with the whole company"
                 },
                 turn_context
               )

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
      turn_context = live_turn_context!(context.agent.uid, event)

      assert {:ok, result} =
               Tools.execute(
                 "remember",
                 %{
                   "claim" => "The target team uses bronze status markers",
                   "kind" => "preference",
                   "scope" => "group:" <> target_group.name,
                   "provenance" => "group conversation"
                 },
                 turn_context
               )

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

      assert {:error, {:writer_not_in_scope_group, _name}} =
               Tools.execute(
                 "remember",
                 %{
                   "claim" => "The inaccessible team uses bronze status markers",
                   "kind" => "preference",
                   "scope" => "group:" <> inaccessible_group.name,
                   "provenance" => "test conversation"
                 },
                 context.context
               )
    end

    test "a group without a member Group rejects an omitted scope", context do
      channel = insert_channel!(:im_group, nil)
      event = insert_actor_event!(context.agent.uid, nil, channel.id)
      turn_context = turn_context!(context.agent.uid, event)

      assert {:error, :im_group_without_member_group} =
               Tools.execute(
                 "remember",
                 %{
                   "claim" => "The team uses bronze status markers",
                   "kind" => "preference",
                   "provenance" => "group conversation"
                 },
                 turn_context
               )
    end

    test "a write from a superseded turn does not land", context do
      channel = insert_channel!(:im_dm, nil)
      event = insert_actor_event!(context.agent.uid, nil, channel.id)
      turn_context = turn_context!(context.agent.uid, event)

      # No activation names this event as its current event, so the fence
      # refuses the write while reads stay open.
      assert {:error, :turn_not_live} =
               Tools.execute(
                 "remember",
                 %{"claim" => "Late write", "kind" => "fact", "provenance" => "test"},
                 turn_context
               )

      assert {:ok, _result} =
               Tools.execute("recall", %{"query" => "wire format"}, turn_context)
    end
  end

  describe "context" do
    test "an actor event that belongs to another Agent is refused", context do
      %{principal: other} = agent_fixture()
      channel = insert_channel!(:im_dm, nil)
      event = insert_actor_event!(other.uid, nil, channel.id)

      assert {:error, :actor_event_not_owned} =
               BrainContext.build(context.agent.uid, %{"actor_event_id" => event.id})

      assert {:error, :actor_event_not_found} =
               BrainContext.build(context.agent.uid, %{
                 "actor_event_id" => Ankole.Ecto.UUIDv7.autogenerate()
               })
    end

    test "a subject without an event runs as itself", _context do
      %{principal: human} = human_fixture()

      assert {:ok, human_context} = BrainContext.build(human.uid, %{})
      assert human_context.querier_uid == human.uid
      assert human_context.default_write_scope == {:ok, "principal:" <> human.uid}
      assert human_context.parent_fallback == {:page, "people/" <> human.uid}
      assert human_context.holder_default == "people/" <> human.uid
      assert human_context.participant_uids == [human.uid]
      assert is_nil(human_context.write_fence)
    end
  end

  describe "disclosure" do
    setup context do
      %{principal: asker} = human_fixture(%{uid: unique_uid("brain-disclosure-asker")})

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
      refute recalled?(context, turn_context!(context.agent.uid, event))
    end

    test "relaxed group chat checks only the asker", context do
      {:ok, _agent} =
        Ankole.Principals.update_agent(context.agent.uid, %{
          group_memory_disclosure_mode: :relaxed
        })

      event = insert_actor_event!(context.agent.uid, context.asker.uid, context.group_channel.id)
      assert recalled?(context, turn_context!(context.agent.uid, event))
    end

    test "a private chat behaves the same under the strict default", context do
      event = insert_actor_event!(context.agent.uid, context.asker.uid, context.dm_channel.id)
      assert recalled?(context, turn_context!(context.agent.uid, event))
    end

    # A cron fire and a check-back wakeup carry no sender and still deliver
    # into a channel, so the channel has to name the recipients: with none,
    # the Turn would speak whatever the Agent itself can reach.
    test "a scheduled private chat protects the reader it delivers to", context do
      insert_entry!(context.dm_channel.id, context.bystander.uid)
      event = insert_actor_event!(context.agent.uid, nil, context.dm_channel.id)
      refute recalled?(context, turn_context!(context.agent.uid, event))
    end

    test "a scheduled private chat still serves its own reader", context do
      insert_entry!(context.dm_channel.id, context.asker.uid)
      event = insert_actor_event!(context.agent.uid, nil, context.dm_channel.id)
      assert recalled?(context, turn_context!(context.agent.uid, event))
    end

    test "a scheduled group chat checks the members in relaxed mode too", context do
      {:ok, _agent} =
        Ankole.Principals.update_agent(context.agent.uid, %{
          group_memory_disclosure_mode: :relaxed
        })

      event = insert_actor_event!(context.agent.uid, nil, context.group_channel.id)
      refute recalled?(context, turn_context!(context.agent.uid, event))
    end

    test "a scheduled group chat discloses nothing when its member group is unavailable",
         context do
      unresolved_channel = insert_channel!(:im_group, nil)
      event = insert_actor_event!(context.agent.uid, nil, unresolved_channel.id)
      refute recalled?(context, turn_context!(context.agent.uid, event))
    end

    test "a strict group chat does not degrade to asker-only disclosure", context do
      unresolved_channel = insert_channel!(:im_group, nil)
      event = insert_actor_event!(context.agent.uid, context.asker.uid, unresolved_channel.id)
      refute recalled?(context, turn_context!(context.agent.uid, event))
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

      refute recalled?(context, turn_context!(context.agent.uid, event))
    end

    test "a subject without an event reaches its own knowledge boundary", context do
      # The Agent wrote the private fact, so it reaches it as author when it
      # answers nobody in particular.
      assert recalled?(context, context.context)
    end

    defp recalled?(context, brain_context) do
      assert {:ok, result} =
               Tools.execute("recall", %{"query" => "wire format secret"}, brain_context)

      context.private_fact.id in Enum.map(result["claims"], & &1["id"])
    end
  end

  test "the context pack carries what a participant holds in this channel", context do
    %{principal: speaker} = human_fixture()
    speaker_slug = "people/" <> speaker.uid
    channel = insert_channel!(:im_dm, nil)
    event = insert_actor_event!(context.agent.uid, speaker.uid, channel.id)
    turn_context = turn_context!(context.agent.uid, event)

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

    pack = Tools.context_pack(turn_context, %{participant_uids: [speaker.uid], recent_text: ""})
    assert [card] = pack.entities
    assert card.slug == speaker_slug
    assert Enum.any?(card.facts, &(&1.claim =~ "written summary"))
  end

  describe "learn_source" do
    test "a channel-less request defaults to the agent's own scope and enqueues the run",
         context do
      url = "https://example.com/paper-#{System.unique_integer([:positive])}"

      assert {:ok, result} = Tools.execute("learn_source", %{"url" => url}, context.context)
      assert result["status"] == "learning"
      assert result["audience_scope"] == "principal:" <> context.agent.uid

      source = Repo.get_by!(Ankole.Brain.Schemas.Source, kind: "url", upstream_id: url)
      assert source.default_audience_scope == "principal:" <> context.agent.uid

      assert [_job] =
               Repo.all(
                 from job in Oban.Job, where: job.worker == "Ankole.Brain.Jobs.LearnSource"
               )

      # The same url reuses the Source and re-runs learning.
      assert {:ok, again} = Tools.execute("learn_source", %{"url" => url}, context.context)
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
      turn_context = live_turn_context!(context.agent.uid, event)

      url = "https://example.com/dm-#{System.unique_integer([:positive])}"

      assert {:ok, result} = Tools.execute("learn_source", %{"url" => url}, turn_context)
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
      turn_context = live_turn_context!(context.agent.uid, event)

      url = "https://example.com/group-#{System.unique_integer([:positive])}"

      assert {:ok, result} = Tools.execute("learn_source", %{"url" => url}, turn_context)
      assert result["audience_scope"] == "group:" <> group.name
    end

    test "a group without a member group names the blocker instead of guessing", context do
      channel = insert_channel!(:im_group, nil)
      event = insert_actor_event!(context.agent.uid, nil, channel.id)
      turn_context = live_turn_context!(context.agent.uid, event)

      url = "https://example.com/orphan-#{System.unique_integer([:positive])}"

      assert {:error, :im_group_without_member_group} =
               Tools.execute("learn_source", %{"url" => url}, turn_context)
    end

    test "an explicit world scope applies and a non-http url is refused", context do
      url = "https://example.com/world-#{System.unique_integer([:positive])}"

      assert {:ok, result} =
               Tools.execute("learn_source", %{"url" => url, "scope" => "world"}, context.context)

      assert result["audience_scope"] == "world"

      assert {:error, :invalid_url} =
               Tools.execute(
                 "learn_source",
                 %{"url" => "ftp://example.com/file"},
                 context.context
               )
    end
  end

  # A turn context whose write fence is open: the event is the current event
  # of a live activation.
  defp live_turn_context!(agent_uid, event) do
    insert_live_activation!(agent_uid, event)
    turn_context!(agent_uid, event)
  end

  defp turn_context!(agent_uid, event) do
    {:ok, context} = BrainContext.build(agent_uid, %{"actor_event_id" => event.id})
    context
  end

  defp insert_live_activation!(agent_uid, event) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(%Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation{
      agent_uid: agent_uid,
      session_id: event.session_id,
      activation_uid: "activation-#{System.unique_integer([:positive])}",
      actor_epoch: 1,
      status: "active",
      controller_node: "test",
      lease_id: "lease-#{System.unique_integer([:positive])}",
      lease_expires_at: DateTime.add(now, 60, :second),
      assigned_worker_id: "worker-#{System.unique_integer([:positive])}",
      current_actor_event_id: event.id,
      revision: 0,
      started_at: now,
      metadata: %{},
      inserted_at: now,
      updated_at: now
    })
  end

  defp insert_channel!(kind, principal_group_id) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(
      Ankole.SignalsGateway.Channel.changeset(%Ankole.SignalsGateway.Channel{}, %{
        id: "test:tools-#{System.unique_integer([:positive])}",
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
end
