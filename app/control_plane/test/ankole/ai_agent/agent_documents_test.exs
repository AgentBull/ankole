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
