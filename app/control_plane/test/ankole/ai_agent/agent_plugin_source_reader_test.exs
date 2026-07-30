defmodule Ankole.AIAgent.Library.AgentPlugins.SourceReaderTest do
  use ExUnit.Case, async: true

  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.AIAgent.Library.AgentPlugins.SourceReader

  test "duplicate trusted roots fail explicitly even for byte-identical packages" do
    source = Path.expand("../../../../library/agent-plugins/deep-research", __DIR__)
    first_root = tmp_root!("conflict-a")
    second_root = tmp_root!("conflict-b")
    File.mkdir_p!(Path.join(first_root, "agent-plugins"))
    File.mkdir_p!(Path.join(second_root, "agent-plugins"))
    File.cp_r!(source, Path.join([first_root, "agent-plugins", "deep-research"]))
    File.cp_r!(source, Path.join([second_root, "agent-plugins", "deep-research"]))

    assert {:error, {:agent_plugin_conflicts, [%{id: "deep-research"} = conflict]}} =
             SourceReader.read_trusted_agent_plugins(roots: [first_root, second_root])

    assert conflict.versions == ["1.0.0"]
    assert length(conflict.roots) == 2
  end

  test "the four trusted Agent Plugins are discovered from standard manifests" do
    root = Path.expand("../../../../library", __DIR__)

    assert {:ok, agent_plugins} = SourceReader.read_trusted_agent_plugins(roots: [root])
    assert Enum.map(agent_plugins, & &1.id) == ["deep-research", "github", "lark", "office"]

    plugin = Enum.find(agent_plugins, &(&1.id == "deep-research"))

    assert plugin.id == "deep-research"
    assert plugin.version == "1.0.0"
    assert plugin.has_workspace_template
    assert Enum.map(plugin.skills, & &1.name) == ["create-deep-research"]

    assert hd(plugin.skills).relative_path ==
             "agent-plugins/deep-research/skills/create-deep-research"

    assert hd(plugin.skills).metadata["skill_root"] == "library"
    assert hd(plugin.skills).metadata["agent_plugin_id"] == "deep-research"
    assert hd(plugin.skills).metadata["ankole-runtime"] == "main"
    refute Map.has_key?(plugin, :files)
    refute Map.has_key?(plugin, :ankole)

    github = Enum.find(agent_plugins, &(&1.id == "github"))

    assert github.version == "1.3.0"

    assert Enum.map(github.skills, & &1.name) == [
             "github-auth",
             "github-issues",
             "github-pr-workflow",
             "github-repo-management",
             "github-webhooks"
           ]
  end

  test "GitHub stays disabled until the installation enables it" do
    source = Path.expand("../../../../library/agent-plugins/deep-research", __DIR__)
    root = tmp_root!("github-default")
    package_root = Path.join([root, "agent-plugins", "github"])
    File.mkdir_p!(Path.dirname(package_root))
    File.cp_r!(source, package_root)

    manifest_path = Path.join(package_root, ".codex-plugin/plugin.json")

    manifest =
      manifest_path
      |> File.read!()
      |> Ankole.JSON.decode!()
      |> Map.put("name", "github")

    File.write!(manifest_path, Ankole.JSON.encode!(manifest))

    assert {:ok, [capability]} =
             AgentPlugins.global_capabilities(
               library_roots: [root],
               agent_library_defaults: %{agent_plugins: %{}, skills: %{}}
             )

    refute capability["global_default_enabled"]
    refute capability["effective_enabled"]
  end

  test "standard manifest components outside Skills are left to Codex" do
    source = Path.expand("../../../../library/agent-plugins/deep-research", __DIR__)
    root = tmp_root!("codex-owned-manifest")
    package_root = Path.join([root, "agent-plugins", "deep-research"])
    File.mkdir_p!(Path.dirname(package_root))
    File.cp_r!(source, package_root)

    hooks_root = Path.join(package_root, "hooks")
    File.mkdir_p!(hooks_root)
    File.write!(Path.join(hooks_root, "session.json"), ~s({"hooks":{}}))
    File.write!(Path.join(hooks_root, "tools.json"), ~s({"hooks":{}}))

    manifest_path = Path.join(package_root, ".codex-plugin/plugin.json")

    manifest =
      manifest_path
      |> File.read!()
      |> Ankole.JSON.decode!()
      |> Map.put("hooks", ["./hooks/session.json", "./hooks/tools.json"])

    File.write!(manifest_path, Ankole.JSON.encode!(manifest))

    assert {:ok, [plugin]} = SourceReader.read_trusted_agent_plugins(roots: [root])
    assert plugin.manifest["hooks"] == ["./hooks/session.json", "./hooks/tools.json"]
  end

  defp tmp_root!(name) do
    root =
      Path.join(
        System.tmp_dir!(),
        "ankole-agent-plugin-test-#{name}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
