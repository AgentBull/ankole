defmodule Ankole.AIAgent.SkillsPersonalAndSaveCardTest do
  use Ankole.DataCase, async: false

  import Ecto.Query
  import Ankole.AIGatewayCase, only: [start_response_run: 1]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.{SkillLinter, Skills}
  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.Conversations
  alias Ankole.Conversations.{ActionCard, NativeRoom}
  alias Ankole.Sessions.{Admission, Model, Run, Tools}
  alias Ankole.Sessions.Prompt.Input
  alias Ankole.Signals.Signal

  @valid_skill_md """
  ---
  name: SQL Cursor Pagination Audit
  description: Audit keyset cursor pagination queries when reviewing PostgreSQL endpoints or fixing offset slowdowns.
  ---
  ## When to Use
  Use when inspecting paginated SQL queries or diagnosing slow offset scans.

  ## Procedure
  1. Check composite index ordering against the `WHERE` tuple comparison.
  2. Verify deterministic tie-breaker columns (`id`) are included at the tail.

  ## Pitfalls
  - Never mix `ASC` and `DESC` inside row-value comparisons without matching index sort direction.

  ## Verification
  Run `EXPLAIN (ANALYZE, BUFFERS)` and confirm an Index Scan without Sort nodes.
  """

  setup do
    root =
      Path.join(System.tmp_dir!(), "ankole-personal-skills-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "skills"))
    previous = Application.get_env(:ankole, Library, [])

    Application.put_env(:ankole, Library,
      library_root: root,
      internal_skills_root: nil,
      source_cache_ttl_ms: 0
    )

    on_exit(fn ->
      Application.put_env(:ankole, Library, previous)
      File.rm_rf!(root)
    end)

    worker_provider_fixture(%{is_default: true})
    alice = human_fixture(%{display_name: "Alice"}).principal
    bob = human_fixture(%{display_name: "Bob"}).principal
    admin = human_fixture(%{display_name: "Admin"}).principal

    for action <- ["read", "create", "update", "delete"] do
      {:ok, _} =
        Ankole.AuthZ.create_permission_grant(%{
          principal_uid: admin.uid,
          resource_pattern: "tenant_console:**",
          action: action
        })
    end

    {:ok, %{principal: alice_assistant}} = Ankole.Principals.ensure_personal_assistant(alice.uid)
    {:ok, %{principal: bob_assistant}} = Ankole.Principals.ensure_personal_assistant(bob.uid)

    colleague =
      Ankole.SessionsCase.agent_fixture(%{
        owner_principal_uid: admin.uid,
        display_name: "Release Engineer"
      }).principal

    for human <- [alice, bob, admin], agent <- [colleague] do
      Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)
    end

    %{
      root: root,
      alice: alice,
      bob: bob,
      admin: admin,
      alice_actor: actor_fixture(alice),
      bob_actor: actor_fixture(bob),
      admin_actor: actor_fixture(admin),
      alice_assistant: alice_assistant,
      bob_assistant: bob_assistant,
      colleague: colleague
    }
  end

  describe "personal vs workspace skill domain model" do
    test "ordinary member creates personal skills with auto-slug, CJK fallback, and reserved-slug protection",
         ctx do
      # Alice lacks tenant_console:custom_skills, so workspace creation is forbidden.
      assert {:error, {:forbidden, _}} =
               Skills.create(ctx.alice_actor, %{
                 slug: "team-SOP",
                 manifest_xml: "<page><p>Team SOP</p></page>",
                 metadata: %{"name" => "Team SOP", "description" => "Shared team workflow"}
               })

      # Personal creation succeeds without tenant_console:custom_skills and auto-generates slug.
      assert {:ok, first} =
               Skills.create(ctx.alice_actor, %{
                 personal: true,
                 slug: "",
                 manifest_xml: "<page><p>First workflow</p></page>",
                 metadata: %{
                   "name" => "Weekly Release Checklist",
                   "description" => "Run weekly release checks"
                 }
               })

      assert first.slug == "weekly-release-checklist"
      assert first.agent_uid == ctx.alice_assistant.uid
      assert first.source_kind == :custom
      refute first.enabled_for_all
      assert Skills.bound_agents(first.id) == []

      # Duplicate title auto-increments slug (-2) instead of failing when slug is blank.
      assert {:ok, second} =
               Skills.create(ctx.alice_actor, %{
                 personal: true,
                 manifest_xml: "<page><p>Second workflow</p></page>",
                 metadata: %{
                   "name" => "Weekly Release Checklist",
                   "description" => "Updated checklist variant"
                 }
               })

      assert second.slug == "weekly-release-checklist-2"

      # Pure CJK title falls back to deterministic custom-skill* slug.
      assert {:ok, cjk} =
               Skills.create(ctx.alice_actor, %{
                 personal: true,
                 manifest_xml: "<page><p>中文流程</p></page>",
                 metadata: %{"name" => "周报复盘标准流程", "description" => "自动整理每周复盘"}
               })

      assert String.starts_with?(cjk.slug, "custom-skill")

      # Reserved slash command slugs are rejected.
      for reserved <- ~w(learn new compress retry steer stop llm invite rename page model) do
        assert {:error, :reserved_skill_slug} =
                 Skills.create(ctx.alice_actor, %{
                   personal: true,
                   slug: reserved,
                   manifest_xml: "<page><p>Body</p></page>",
                   metadata: %{"name" => "Reserved", "description" => "Reserved test"}
                 })
      end

      # Attaching a private skill to an ai_colleague is rejected.
      assert {:error, :personal_skill_requires_assistant} =
               Skills.create(ctx.admin_actor, %{
                 agent_uid: ctx.colleague.uid,
                 slug: "colleague-private",
                 manifest_xml: "<page><p>Body</p></page>",
                 metadata: %{"name" => "Invalid", "description" => "Must fail"}
               })
    end

    test "enforces strict read, write, binding, Console, and runtime isolation across members",
         ctx do
      assert {:ok, personal} =
               Skills.create(ctx.alice_actor, %{
                 personal: true,
                 slug: "alice-secret-playbook",
                 manifest_xml: "<page><p>Alice private instructions</p></page>",
                 metadata: %{
                   "name" => "Alice Playbook",
                   "description" => "Only for Alice's assistant"
                 }
               })

      assert {:ok, _} =
               Skills.put_file(
                 ctx.alice_actor,
                 personal.slug,
                 "references/notes.md",
                 "Private ref",
                 %{
                   base_revision: personal.revision
                 }
               )

      assert {:ok, personal} = Skills.get(personal.slug)

      # Runtime enablement: enabled ONLY for Alice's personal assistant.
      assert {:ok, alice_enabled} = Library.enabled_skills_for_agent(ctx.alice_assistant.uid)
      assert Enum.any?(alice_enabled, &(&1["skill_name"] == personal.slug))

      assert {:ok, bob_enabled} = Library.enabled_skills_for_agent(ctx.bob_assistant.uid)
      refute Enum.any?(bob_enabled, &(&1["skill_name"] == personal.slug))

      assert {:ok, colleague_enabled} = Library.enabled_skills_for_agent(ctx.colleague.uid)
      refute Enum.any?(colleague_enabled, &(&1["skill_name"] == personal.slug))

      assert {:ok, %{"content" => content}} =
               Library.skill_view(ctx.alice_assistant.uid, personal.slug)

      assert content =~ "Alice private instructions"

      assert {:error, :skill_not_enabled} =
               Library.skill_view(ctx.bob_assistant.uid, personal.slug)

      assert {:error, :skill_not_enabled} = Library.skill_view(ctx.colleague.uid, personal.slug)

      # Visibility & mutation isolation: Bob cannot view/edit/delete Alice's personal skill via Skills API!
      assert {:ok, alice_list} = Skills.list(ctx.alice_actor)
      assert Enum.any?(alice_list, &(&1.id == personal.id))

      assert {:ok, bob_list} = Skills.list(ctx.bob_actor)
      refute Enum.any?(bob_list, &(&1.id == personal.id))

      assert {:error, :not_found} = Skills.detail(ctx.bob_actor, personal.slug)

      assert {:error, :not_found} =
               Skills.save(ctx.bob_actor, personal.slug, %{
                 base_revision: personal.revision,
                 manifest_xml: "<page><p>Tamper</p></page>",
                 metadata: personal.metadata
               })

      assert {:error, :not_found} =
               Skills.delete(ctx.bob_actor, personal.slug, personal.revision)

      # Non-owner calling set_all gets :not_found (no existence leak); owner calling set_all gets :private_skill.
      assert {:error, :not_found} =
               Skills.set_all(ctx.admin_actor, personal.slug, true, personal.revision)

      {:ok, %{principal: _}} = Ankole.Principals.ensure_personal_assistant(ctx.admin.uid)

      assert {:ok, admin_personal} =
               Skills.create(ctx.admin_actor, %{
                 personal: true,
                 slug: "admin-private-skill",
                 manifest_xml: "<page><p>Admin only</p></page>",
                 metadata: %{"name" => "Admin Private", "description" => "Admin assistant skill"}
               })

      assert {:error, :private_skill} =
               Skills.set_all(
                 ctx.admin_actor,
                 admin_personal.slug,
                 true,
                 admin_personal.revision
               )

      assert {:error, :private_skill} =
               Skills.set_binding(
                 ctx.alice_actor,
                 personal.slug,
                 ctx.alice_assistant.uid,
                 false
               )

      assert {:error, :private_skill} =
               Skills.set_binding(
                 ctx.admin_actor,
                 admin_personal.slug,
                 ctx.colleague.uid,
                 true
               )

      assert {:error, :private_skill} =
               Ankole.Repo.transact_top_level(fn ->
                 Skills.bind_in_tx(personal.id, ctx.colleague.uid, true)
               end)

      # Console global capabilities exclude personal skills; per-agent capabilities include them only for owner assistant.
      assert {:ok, global_caps} = Library.global_capabilities()
      refute Enum.any?(global_caps["skills"], &(&1["id"] == personal.slug))

      assert {:ok, alice_caps} = Library.capabilities_for_agent(ctx.alice_assistant.uid)

      assert Enum.any?(
               alice_caps["skills"],
               &(&1["id"] == personal.slug and &1["effective_enabled"])
             )

      assert {:ok, colleague_caps} = Library.capabilities_for_agent(ctx.colleague.uid)
      refute Enum.any?(colleague_caps["skills"], &(&1["id"] == personal.slug))
    end

    test "publish_to_workspace promotes a personal skill atomically while preserving owner assistant binding",
         ctx do
      {:ok, %{principal: admin_assistant}} =
        Ankole.Principals.ensure_personal_assistant(ctx.admin.uid)

      assert {:ok, personal} =
               Skills.create(ctx.admin_actor, %{
                 personal: true,
                 slug: "incident-triage",
                 manifest_xml: "<page><p>Triage steps</p></page>",
                 metadata: %{
                   "name" => "Incident Triage",
                   "description" => "Structured incident triage workflow"
                 }
               })

      assert personal.agent_uid == admin_assistant.uid
      assert Skills.bound_agents(personal.id) == []

      # Member without custom_skills permission cannot publish their personal skill.
      assert {:ok, alice_personal} =
               Skills.create(ctx.alice_actor, %{
                 personal: true,
                 slug: "alice-draft",
                 manifest_xml: "<page><p>Draft</p></page>",
                 metadata: %{"name" => "Alice Draft", "description" => "Draft"}
               })

      assert {:error, {:forbidden, _}} =
               Skills.publish_to_workspace(
                 ctx.alice_actor,
                 alice_personal.slug,
                 alice_personal.revision
               )

      # Authorized owner publishes to workspace: agent_uid becomes nil and owner assistant gets explicit AgentSkill row.
      assert {:ok, published} =
               Skills.publish_to_workspace(ctx.admin_actor, personal.slug, personal.revision)

      assert is_nil(published.agent_uid)
      assert published.created_by == ctx.admin.uid
      assert Skills.bound_agents(published.id) == [admin_assistant.uid]

      assert {:ok, admin_enabled} = Library.enabled_skills_for_agent(admin_assistant.uid)
      assert Enum.any?(admin_enabled, &(&1["skill_name"] == published.slug))

      # Now it can be bound to AI colleagues and seen by Bob.
      assert {:ok, _} =
               Skills.set_binding(ctx.admin_actor, published.slug, ctx.colleague.uid, true)

      assert {:ok, bob_list} = Skills.list(ctx.bob_actor)
      assert Enum.any?(bob_list, &(&1.id == published.id))
    end
  end

  describe "SkillLinter and library.skill.save ActionCard" do
    test "SkillLinter enforces secret hygiene, invisible character stripping, and concise trigger frontmatter" do
      # Valid skill passes and strips zero-width characters.
      zwsp_md = String.replace(@valid_skill_md, "keyset", "key\u200Bset")
      assert {:ok, %{slug: slug, content: parsed}} = SkillLinter.validate_and_parse(zwsp_md, nil)
      assert slug == "sql-cursor-pagination-audit"
      assert parsed.manifest_markdown =~ "keyset"
      refute String.contains?(parsed.manifest_markdown, "\u200B")

      # Bidi override is rejected.
      assert {:error, msg} =
               SkillLinter.validate_and_parse(@valid_skill_md <> "\n\u202Ehidden", "bidi-skill")

      assert msg =~ "bidirectional"

      # Embedded API keys / tokens are rejected.
      secret_md =
        @valid_skill_md <> "\nUse `Authorization: Bearer sk-abcdefgh1234567890ijklmnop`.\n"

      assert {:error, secret_msg} = SkillLinter.validate_and_parse(secret_md, "secret-skill")
      assert secret_msg =~ "credential" or secret_msg =~ "secret"

      # Short or missing description is rejected.
      bad_desc = """
      ---
      name: Too Short
      description: tiny
      ---
      ## When to Use
      Body text that is plenty long enough to pass body length checks easily.
      """

      assert {:error, desc_msg} = SkillLinter.validate_and_parse(bad_desc, "short-desc")
      assert desc_msg =~ "description"
    end

    test "library.skill.save drafts personal ownership by default, enforces CAS on updates, and cascades assistant rename",
         ctx do
      room_id = Ecto.UUID.generate()

      assert {:ok, _} =
               Conversations.create(ctx.alice_actor, %{
                 conversation_id: room_id,
                 agent_uid: ctx.colleague.uid,
                 room_mode: :group,
                 message_id: Ecto.UUID.generate(),
                 text: "Help me audit cursor pagination."
               })

      assert {:ok, _} = NativeRoom.manage(ctx.alice_actor, room_id, %{add_uids: [ctx.bob.uid]})
      event = Repo.one!(from(s in Signal, where: s.conversation_id == ^room_id))

      message =
        propose_native_card(ctx.colleague.uid, event, "skill-create-1", %{
          "action_kind" => "library.skill.save",
          "summary" => "Save SQL Cursor Pagination Audit to your Personal Assistant",
          "markdown" => @valid_skill_md
        })

      card_id = message.rich_content["action_card"]["card_id"]
      card = Repo.get_by!(ActionCard, id: card_id)
      assert card.payload["target"] == "personal"
      assert card.payload["agent_uid"] == ctx.alice_assistant.uid
      assert card.payload["slug"] == "sql-cursor-pagination-audit"

      # Bob is in the same group room, but cannot confirm Alice's personal assistant skill!
      assert {:error, :forbidden} =
               Conversations.resolve_action_card(ctx.bob_actor, room_id, card_id, :confirm)

      # Alice confirms and creates her personal skill.
      assert {:ok, _} =
               Conversations.resolve_action_card(ctx.alice_actor, room_id, card_id, :confirm)

      assert {:ok, created} = Skills.get("sql-cursor-pagination-audit")
      assert created.agent_uid == ctx.alice_assistant.uid
      assert created.revision == 1

      # Post a fresh user message so the next turn has a fresh signal to propose an update card.
      assert {:ok, _} =
               Conversations.post(ctx.alice_actor, room_id, %{
                 message_id: Ecto.UUID.generate(),
                 text: "Update the skill with covering index guidance."
               })

      next_event =
        Repo.one!(
          from(s in Signal,
            where: s.conversation_id == ^room_id and s.type == "conversation.message.addressed",
            order_by: [desc: s.inserted_at],
            limit: 1
          )
        )

      updated_md =
        String.replace(@valid_skill_md, "composite index ordering", "covering keyset index order")

      update_msg =
        propose_native_card(ctx.colleague.uid, next_event, "skill-update-1", %{
          "action_kind" => "library.skill.save",
          "summary" => "Refine index guidance",
          "slug" => created.slug,
          "base_revision" => created.revision,
          "markdown" => updated_md
        })

      update_card_id = update_msg.rich_content["action_card"]["card_id"]
      update_card = Repo.get_by!(ActionCard, id: update_card_id)
      assert update_card.payload["operation"] == "update"
      assert update_card.payload["diff"] =~ "covering keyset index order"
      assert update_card.preconditions["expected_revision"] == 1

      # Persisted message text and stored rich_content do not leak Alice's private skill body/diff,
      # and Bob's group-room projection receives a redacted card he cannot confirm or cancel.
      refute update_msg.text =~ "composite index ordering"
      refute update_msg.text =~ "covering keyset index order"
      assert update_msg.rich_content["action_card"]["payload"]["redacted"] == true
      refute Map.has_key?(update_msg.rich_content["action_card"]["payload"], "diff")

      assert {:ok, bob_room_detail} = Conversations.get(ctx.bob_actor, room_id)

      bob_card_msg =
        bob_room_detail
        |> Ankole.Pod.Chat.Presentation.detail()
        |> Map.fetch!(:messages)
        |> Enum.find(&(&1.id == update_msg.id))

      assert bob_card_msg.richContent["action_card"]["payload"]["redacted"] == true
      refute Map.has_key?(bob_card_msg.richContent["action_card"]["payload"], "diff")
      refute Map.has_key?(bob_card_msg.richContent["action_card"]["payload"], "markdown")

      assert {:error, :forbidden} =
               Conversations.resolve_action_card(ctx.bob_actor, room_id, update_card_id, :cancel)

      assert {:ok, alice_room_detail} = Conversations.get(ctx.alice_actor, room_id)

      alice_card_msg =
        alice_room_detail
        |> Ankole.Pod.Chat.Presentation.detail()
        |> Map.fetch!(:messages)
        |> Enum.find(&(&1.id == update_msg.id))

      refute alice_card_msg.richContent["action_card"]["payload"]["redacted"]

      assert alice_card_msg.richContent["action_card"]["payload"]["diff"] =~
               "covering keyset index order"

      assert is_binary(alice_card_msg.richContent["action_card"]["payload"]["markdown"])

      # Concurrent direct edit bumps revision to 2.
      assert {:ok, bumped} =
               Skills.save(ctx.alice_actor, created.slug, %{
                 base_revision: 1,
                 manifest_xml: "<page><p>Concurrent manual edit</p></page>",
                 metadata: created.metadata
               })

      assert bumped.revision == 2

      assert {:ok, detail} =
               Conversations.resolve_action_card(
                 ctx.alice_actor,
                 room_id,
                 update_card_id,
                 :confirm
               )

      stale_card = Repo.get_by!(ActionCard, id: update_card_id)
      assert stale_card.status == :stale
      assert detail.conversation.id == room_id

      # Renaming Alice's personal assistant cascades to skills.agent_uid AND action_card.payload["agent_uid"]!
      new_assistant_uid = "alice-pa-#{System.unique_integer([:positive])}"

      assert {:ok, _} = Ankole.Principals.disable_agent(ctx.alice_assistant.uid)

      assert {:ok, _} =
               Ankole.Principals.rename(ctx.alice_assistant.uid, new_assistant_uid)

      assert {:ok, _} = Ankole.Principals.enable_agent(new_assistant_uid)

      assert {:ok, renamed_skill} = Skills.get(created.slug)
      assert renamed_skill.agent_uid == new_assistant_uid
      assert Repo.get_by!(ActionCard, id: card_id).payload["agent_uid"] == new_assistant_uid
    end

    test "workspace target in ai_colleague room binds colleague when authorized and falls back to personal when unauthorized",
         ctx do
      # 1. Unauthorized member requesting target: "workspace" automatically falls back to personal with scope_note.
      alice_room = Ecto.UUID.generate()

      assert {:ok, _} =
               Conversations.create(ctx.alice_actor, %{
                 conversation_id: alice_room,
                 agent_uid: ctx.colleague.uid,
                 room_mode: :dm,
                 message_id: Ecto.UUID.generate(),
                 text: "Capture this for the team."
               })

      alice_event = Repo.one!(from(s in Signal, where: s.conversation_id == ^alice_room))

      fallback_msg =
        propose_native_card(ctx.colleague.uid, alice_event, "fallback-ws", %{
          "action_kind" => "library.skill.save",
          "summary" => "Save release verification workflow",
          "target" => "workspace",
          "slug" => "alice-fallback-skill",
          "markdown" => @valid_skill_md
        })

      fallback_card =
        Repo.get_by!(ActionCard, id: fallback_msg.rich_content["action_card"]["card_id"])

      assert fallback_card.payload["target"] == "personal"
      assert fallback_card.payload["agent_uid"] == ctx.alice_assistant.uid
      assert is_binary(fallback_card.payload["scope_note"])

      # 2. Authorized admin requesting target: "workspace" creates workspace skill and binds colleague.
      admin_room = Ecto.UUID.generate()

      assert {:ok, _} =
               Conversations.create(ctx.admin_actor, %{
                 conversation_id: admin_room,
                 agent_uid: ctx.colleague.uid,
                 room_mode: :dm,
                 message_id: Ecto.UUID.generate(),
                 text: "Teach Release Engineer this workflow."
               })

      admin_event = Repo.one!(from(s in Signal, where: s.conversation_id == ^admin_room))

      ws_msg =
        propose_native_card(ctx.colleague.uid, admin_event, "admin-ws", %{
          "action_kind" => "library.skill.save",
          "summary" => "Save workspace skill and bind Release Engineer",
          "target" => "workspace",
          "slug" => "team-cursor-audit",
          "markdown" => @valid_skill_md
        })

      ws_card_id = ws_msg.rich_content["action_card"]["card_id"]
      ws_card = Repo.get_by!(ActionCard, id: ws_card_id)
      assert ws_card.payload["target"] == "workspace"
      assert is_nil(ws_card.payload["agent_uid"])
      assert ws_card.payload["bind_agent_uid"] == ctx.colleague.uid

      assert {:ok, _} =
               Conversations.resolve_action_card(
                 ctx.admin_actor,
                 admin_room,
                 ws_card_id,
                 :confirm
               )

      assert {:ok, ws_skill} = Skills.get("team-cursor-audit")
      assert is_nil(ws_skill.agent_uid)
      assert ctx.colleague.uid in Skills.bound_agents(ws_skill.id)
    end

    test "MetaLibrary Browser :list reflects parent AgentPlugin enablement in runtime_assistant_enabled and runtime_agent_uids",
         ctx do
      plugin_dir = Path.join([ctx.root, "agent-plugins", "github"])
      File.mkdir_p!(Path.join(plugin_dir, ".codex-plugin"))
      File.mkdir_p!(Path.join([plugin_dir, "skills", "github-pr-review"]))

      File.write!(
        Path.join([plugin_dir, ".codex-plugin", "plugin.json"]),
        Ankole.JSON.encode!(%{
          "name" => "github",
          "version" => "1.0.0",
          "description" => "GitHub workflows",
          "skills" => "./skills"
        })
      )

      File.write!(
        Path.join([plugin_dir, "skills", "github-pr-review", "SKILL.md"]),
        """
        ---
        name: github-pr-review
        description: Review GitHub pull requests with structured checklist.
        ---
        Check diff coverage and migration safety.
        """
      )

      assert {:ok, _} = Library.sync_agent_skills(ctx.alice_assistant.uid)
      assert {:ok, _} = Library.sync_agent_skills(ctx.colleague.uid)

      # `github` plugin defaults to disabled globally, even though the synced skill row has enabled_for_all: true.
      assert {:ok, listed_disabled} =
               Ankole.Ash.run_action(Ankole.AIAgent.Library.Browser, :list, %{},
                 actor: ctx.alice_actor
               )

      gh_disabled = Enum.find(listed_disabled.skills, &(&1.slug == "github-pr-review"))
      assert gh_disabled.enabled_for_all == true
      assert gh_disabled.runtime_assistant_enabled == false
      assert gh_disabled.runtime_agent_uids == []

      # Enabling parent plugin on colleague and Alice's PA turns on runtime availability.
      assert {:ok, _} =
               Ankole.AIAgent.Library.AgentPlugins.set_agent_override(
                 ctx.colleague.uid,
                 "github",
                 true
               )

      assert {:ok, _} =
               Ankole.AIAgent.Library.AgentPlugins.set_agent_override(
                 ctx.alice_assistant.uid,
                 "github",
                 true
               )

      assert {:ok, listed_enabled} =
               Ankole.Ash.run_action(Ankole.AIAgent.Library.Browser, :list, %{},
                 actor: ctx.alice_actor
               )

      gh_enabled = Enum.find(listed_enabled.skills, &(&1.slug == "github-pr-review"))
      assert gh_enabled.runtime_assistant_enabled == true
      assert ctx.colleague.uid in gh_enabled.runtime_agent_uids
    end
  end

  describe "Sessions.Prompt.Input leading /learn and /<slug> augmentation" do
    test "injects LearnPrompt for /learn and <invoked_skill> only for enabled skills without altering Signals.Commands",
         ctx do
      assert :not_command ==
               Ankole.Signals.Commands.classify("/learn focus on SQL keyset pagination")

      assert :not_command ==
               Ankole.Signals.Commands.classify("/my-personal-skill run audit")

      assert {:ok, personal} =
               Skills.create(ctx.alice_actor, %{
                 personal: true,
                 slug: "my-personal-skill",
                 manifest_xml: "<page><p>Always verify index selectivity first.</p></page>",
                 metadata: %{
                   "name" => "My Personal Skill",
                   "description" => "Personal index selectivity check"
                 }
               })

      room_id = Ecto.UUID.generate()

      assert {:ok, _} =
               Conversations.create(ctx.alice_actor, %{
                 conversation_id: room_id,
                 agent_uid: ctx.alice_assistant.uid,
                 room_mode: :dm,
                 message_id: Ecto.UUID.generate(),
                 text: "/learn focus on SQL keyset pagination"
               })

      learn_event =
        Repo.one!(
          from(s in Signal,
            where: s.conversation_id == ^room_id,
            order_by: [desc: s.inserted_at],
            limit: 1
          )
        )

      {:ok, enabled_skills} = Library.enabled_skills_for_agent(ctx.alice_assistant.uid)

      run = %{
        agent_uid: ctx.alice_assistant.uid,
        session_id: learn_event.session_id,
        context: %{
          conversation: %{timezone: "UTC"},
          skills: enabled_skills
        }
      }

      [learn_user_msg] = Input.messages(run, learn_event)
      rendered_learn = Enum.map_join(learn_user_msg["content"], "\n", &(&1["text"] || ""))
      assert rendered_learn =~ "<skill_extraction_request>"
      assert rendered_learn =~ "my-personal-skill"
      assert rendered_learn =~ "SQL keyset pagination"

      # Leading /my-personal-skill injects <invoked_skill> with full instructions when enabled.
      assert {:ok, _} =
               Conversations.post(ctx.alice_actor, room_id, %{
                 message_id: Ecto.UUID.generate(),
                 text: "/#{personal.slug} check orders query"
               })

      skill_event =
        Repo.one!(
          from(s in Signal,
            where: s.conversation_id == ^room_id,
            order_by: [desc: s.inserted_at],
            limit: 1
          )
        )

      [skill_user_msg] = Input.messages(run, skill_event)
      rendered_skill = Enum.map_join(skill_user_msg["content"], "\n", &(&1["text"] || ""))
      assert rendered_skill =~ ~s(<invoked_skill name="my-personal-skill")
      assert rendered_skill =~ "Always verify index selectivity first."

      # Unenabled /unknown-skill is left untouched without <invoked_skill>.
      assert {:ok, _} =
               Conversations.post(ctx.alice_actor, room_id, %{
                 message_id: Ecto.UUID.generate(),
                 text: "/unknown-skill hello"
               })

      plain_event =
        Repo.one!(
          from(s in Signal,
            where: s.conversation_id == ^room_id,
            order_by: [desc: s.inserted_at],
            limit: 1
          )
        )

      [plain_user_msg] = Input.messages(run, plain_event)
      rendered_plain = Enum.map_join(plain_user_msg["content"], "\n", &(&1["text"] || ""))
      refute rendered_plain =~ "<invoked_skill"
    end
  end

  defp propose_native_card(agent_uid, event, call_id, arguments_map) do
    assert {:ok, run} =
             Admission.admit(%{agent_uid: agent_uid, session_id: event.session_id}, event)

    assert {:ok, {:preparing, run}} = Model.prepare(run)

    call = %{
      "type" => "function_call",
      "name" => "propose_action_card",
      "call_id" => call_id,
      "arguments" => Ankole.JSON.encode!(arguments_map)
    }

    assert {:ok, response} =
             start_response_run(%{
               subject_uid: run.agent_uid,
               conversation_id: run.conversation.id,
               round_state: run,
               metadata: %{"request_metadata" => Run.metadata(run)}
             })

    assert {:ok, response} = ResponseCommit.commit_complete(response, [call])

    run = %{
      run
      | model_response: response,
        calls: [call],
        round_calls: [call],
        anchor: response.id
    }

    assert {:ok, tool, args} = Tools.prepare(run, call)
    result = Tools.execute(run, call, tool, args)
    refute result.is_error
    assert {:ok, _journal} = Run.record_round(%{run | results: %{call["call_id"] => result}})
    assert {:ok, {_state, run}} = Run.restore(run)
    assert {:ok, finalized} = Run.finalize(run)
    List.last(finalized.posted.messages)
  end
end
