defmodule Ankole.AIAgent.AgentDocumentsTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.AIAgent.Library.Contracts

  setup do
    %{principal: human} = human_fixture()
    actor = actor_fixture(human)

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: human.uid,
        resource_pattern: "tenant_console:**",
        action: "update"
      })

    %{actor: actor}
  end

  test "colleagues inherit global contracts without copying them", %{actor: actor} do
    %{principal: one} = agent_fixture()
    %{principal: two} = agent_fixture()
    assert {:ok, nil} = Contracts.get(one.uid, :agents)
    assert {:ok, global} = Contracts.get(nil, :agents)
    assert {:ok, _} = save(actor, nil, :agents, :override, "Organization policy", global.revision)
    assert {:ok, first} = Contracts.effective(one.uid)
    assert {:ok, second} = Contracts.effective(two.uid)
    assert first == second
    assert first["agents"]["content"] =~ "Organization policy"
  end

  test "individual append, override and inherit have explicit composition", %{actor: actor} do
    %{principal: agent} = agent_fixture()
    assert {:ok, global} = Contracts.get(nil, :agents)
    assert {:ok, _} = save(actor, nil, :agents, :override, "Global", global.revision)
    assert {:ok, local} = save(actor, agent.uid, :agents, :append, "Local", 0)
    assert {:ok, result} = Contracts.effective(agent.uid)
    assert result["agents"]["content"] =~ "Global\n\nLocal"
    assert {:ok, local} = save(actor, agent.uid, :agents, :override, "Only local", local.revision)
    assert {:ok, result} = Contracts.effective(agent.uid)
    assert result["agents"]["content"] =~ "Only local"
    refute result["agents"]["content"] =~ "Global"
    assert {:ok, _} = save(actor, agent.uid, :agents, :inherit, "Unused", local.revision)
    assert {:ok, result} = Contracts.effective(agent.uid)
    assert result["agents"]["content"] =~ "Global"
    refute result["agents"]["content"] =~ "Unused"
  end

  test "DESIGN recursively merges mappings, replaces arrays and removes null keys", %{
    actor: actor
  } do
    %{principal: agent} = agent_fixture()
    {:ok, global} = Contracts.get(nil, :design)

    assert {:ok, _} =
             save(
               actor,
               nil,
               :design,
               :override,
               "---\ncolors: {text: black, accent: red}\nfonts: [a, b]\nremove: true\n---\nGlobal",
               global.revision
             )

    assert {:ok, _} =
             save(
               actor,
               agent.uid,
               :design,
               :append,
               "---\ncolors: {accent: blue}\nfonts: [c]\nremove: null\n---\nLocal",
               0
             )

    {:ok, result} = Contracts.effective(agent.uid)
    {:ok, parsed} = Ankole.Kernel.knowledge_parse(result["design"]["content"])

    assert parsed.metadata == %{
             "colors" => %{"text" => "black", "accent" => "blue"},
             "fonts" => ["c"]
           }

    assert result["design"]["content"] =~ "---"
  end

  test "empty override deliberately clears an inherited contract and CAS rejects stale writes", %{
    actor: actor
  } do
    %{principal: agent} = agent_fixture()
    assert {:ok, local} = save(actor, agent.uid, :design, :override, "", 0)
    assert {:ok, result} = Contracts.effective(agent.uid)
    assert String.trim(result["design"]["content"]) == ""
    assert {:ok, _} = save(actor, agent.uid, :design, :override, "first", local.revision)

    assert {:error, :stale} =
             save(actor, agent.uid, :design, :override, "lost", local.revision)
             |> Ankole.Errors.reason()
  end

  test "startup does not replace a human's global edit", %{actor: actor} do
    {:ok, global} = Contracts.get(nil, :agents)
    assert {:ok, saved} = save(actor, nil, :agents, :override, "Human policy", global.revision)
    assert :ok = Ankole.Repo.transact_top_level(fn -> Contracts.initialize_in_tx() end)
    assert {:ok, current} = Contracts.get(nil, :agents)
    assert current.revision == saved.revision
    assert current.content_markdown == saved.content_markdown
  end

  test "only the owner can manage or read personal assistant contracts even with pod_admin", %{
    actor: other
  } do
    %{principal: owner} = human_fixture()
    worker_provider_fixture(%{is_default: true})
    assert {:ok, %{principal: assistant}} = Ankole.Principals.ensure_personal_assistant(owner.uid)

    assert {:ok, %{agents: %{mode: :override}, design: nil}} =
             Contracts.list(actor_fixture(owner), assistant.uid)

    assert {:error, :forbidden} = Contracts.list(other, assistant.uid)
    assert {:error, :forbidden} = save(other, assistant.uid, :agents, :override, "Wrong owner", 0)
    assert {:error, :forbidden} = Contracts.list(actor_fixture(assistant), assistant.uid)
  end

  test "default DESIGN.md defines green-up red-down tokens and migration upgrades only uncustomized global contracts",
       %{actor: actor} do
    migration = Ankole.Repo.Migrations.AddBaseChartViewsAndMigrateDesignDirection

    migration_path =
      Path.expand(
        "../../../priv/repo/migrations/20261106010000_add_base_chart_views_and_migrate_design_direction.exs",
        __DIR__
      )

    unless Code.ensure_loaded?(migration), do: Code.require_file(migration_path)

    raw_template = Ankole.AIAgent.Library.SourceReader.load_default_design_template()
    assert {:ok, parsed_template} = Ankole.Kernel.knowledge_parse(raw_template)
    assert get_in(parsed_template.metadata, ["colors", "chart-up"]) == "#0f8a5f"
    assert get_in(parsed_template.metadata, ["colors", "chart-down"]) == "#c81e3a"

    tenant_id = Ankole.Repo.tenant_id!()
    {:ok, current} = Contracts.get(nil, :design)

    # Case 1: Legacy uncustomized contract matching upstream_base_hash with extra upstream_state key.
    legacy_markdown =
      "---\ncolors:\n  chart-up: \"#b31b5d\"\n  chart-down: \"#24a148\"\n---\nLegacy design\n"

    {:ok, legacy_parsed} = Ankole.Kernel.knowledge_parse(legacy_markdown)

    {:ok, legacy_canonical} =
      Ankole.Kernel.knowledge_export(legacy_parsed.xml, legacy_parsed.metadata)

    legacy_hash = Ankole.Kernel.xxh3_128_hex(legacy_canonical)

    Ankole.Repo.query!(
      """
      UPDATE agent_contracts
      SET content_xml = $2,
          content_markdown = $3,
          metadata = $4::jsonb,
          upstream_state = $5::jsonb,
          updated_by = 'seed-bot',
          revision = 3
      WHERE tenant_id = $1::text::uuid AND id = $6::text::uuid
      """,
      [
        tenant_id,
        legacy_parsed.xml,
        legacy_canonical,
        legacy_parsed.metadata,
        %{"upstream_base_hash" => legacy_hash, "custom_marker" => "keep-me"},
        current.id
      ]
    )

    apply(migration, :migrate_design_contracts!, [Ankole.Repo])

    {:ok, migrated} = Contracts.get(nil, :design)
    assert migrated.revision == 4
    assert get_in(migrated.metadata, ["colors", "chart-up"]) == "#0f8a5f"
    assert get_in(migrated.metadata, ["colors", "chart-down"]) == "#c81e3a"
    assert migrated.upstream_state["status"] == "clean"
    assert migrated.upstream_state["custom_marker"] == "keep-me"

    assert migrated.upstream_state["upstream_base_hash"] ==
             migrated.upstream_state["upstream_latest_hash"]

    # Case 2: Unmodified legacy row where upstream_state was empty and updated_by is NULL.
    Ankole.Repo.query!(
      """
      UPDATE agent_contracts
      SET content_xml = $2,
          content_markdown = $3,
          metadata = $4::jsonb,
          upstream_state = '{}'::jsonb,
          updated_by = NULL,
          revision = 7
      WHERE tenant_id = $1::text::uuid AND id = $5::text::uuid
      """,
      [tenant_id, legacy_parsed.xml, legacy_canonical, legacy_parsed.metadata, current.id]
    )

    apply(migration, :migrate_design_contracts!, [Ankole.Repo])

    {:ok, migrated_legacy} = Contracts.get(nil, :design)
    assert migrated_legacy.revision == 8
    assert get_in(migrated_legacy.metadata, ["colors", "chart-up"]) == "#0f8a5f"
    assert get_in(migrated_legacy.metadata, ["colors", "chart-down"]) == "#c81e3a"

    # Case 3: Human-customized global DESIGN contract is NEVER overwritten by migration.
    custom_markdown =
      "---\ncolors:\n  chart-up: \"#112233\"\n  chart-down: \"#445566\"\n---\nCustom brand direction"

    assert {:ok, customized} =
             save(actor, nil, :design, :override, custom_markdown, migrated_legacy.revision)

    apply(migration, :migrate_design_contracts!, [Ankole.Repo])

    {:ok, preserved} = Contracts.get(nil, :design)
    assert preserved.revision == customized.revision
    assert preserved.content_markdown == customized.content_markdown
    assert get_in(preserved.metadata, ["colors", "chart-up"]) == "#112233"
    assert get_in(preserved.metadata, ["colors", "chart-down"]) == "#445566"
  end

  defp save(actor, uid, slot, mode, markdown, revision) do
    {:ok, parsed} = Ankole.Kernel.knowledge_parse(markdown)

    Contracts.save(actor, uid, slot, %{
      mode: mode,
      content_xml: parsed.xml,
      metadata: parsed.metadata,
      base_revision: revision
    })
  end
end
