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

  test "trusted Agent Plugins are discovered from standard manifests" do
    root = Path.expand("../../../../library", __DIR__)

    assert {:ok, agent_plugins} = SourceReader.read_trusted_agent_plugins(roots: [root])

    plugin = Enum.find(agent_plugins, &(&1.id == "deep-research"))
    research = Enum.find(plugin.skills, &(&1.name == "create-deep-research"))

    assert plugin.version == "1.0.0"
    assert plugin.has_workspace_template
    assert research.relative_path == "agent-plugins/deep-research/skills/create-deep-research"
    assert research.metadata["skill_root"] == "library"
    assert research.metadata["agent_plugin_id"] == "deep-research"
    assert research.metadata["ankole-runtime"] == "main"
    refute Map.has_key?(plugin, :files)
    refute Map.has_key?(plugin, :ankole)

    github = Enum.find(agent_plugins, &(&1.id == "github"))
    assert github.version == "1.3.0"
    assert Enum.any?(github.skills, &(&1.name == "github-auth"))
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

  test "an unreadable manifest is an error rather than an absent Plugin" do
    root = tmp_root!("broken-manifest")
    plugin_root = Path.join([root, "agent-plugins", "broken"])
    File.mkdir_p!(Path.join(plugin_root, ".codex-plugin"))
    File.ln_s!("missing", Path.join(plugin_root, ".codex-plugin/plugin.json"))

    assert {:error, {:agent_plugin_manifest_unreadable, "broken", :enoent}} =
             SourceReader.read_trusted_agent_plugins(roots: [root])
  end

  test "a broken Skill file prevents a partial Plugin inventory" do
    source = Path.expand("../../../../library/agent-plugins/deep-research", __DIR__)
    root = tmp_root!("broken-skill")
    plugin_root = Path.join([root, "agent-plugins", "deep-research"])
    File.mkdir_p!(Path.dirname(plugin_root))
    File.cp_r!(source, plugin_root)
    skill_path = Path.join(plugin_root, "skills/create-deep-research/SKILL.md")
    File.rm!(skill_path)
    File.ln_s!("missing", skill_path)

    assert {:error, {:agent_plugin_skills_unreadable, :enoent}} =
             SourceReader.read_trusted_agent_plugins(roots: [root])
  end

  test "a broken manifest directory cannot hide an installed Plugin" do
    root = tmp_root!("broken-manifest-directory")
    plugin_root = Path.join([root, "agent-plugins", "broken"])
    File.mkdir_p!(plugin_root)
    File.ln_s!("missing", Path.join(plugin_root, ".codex-plugin"))

    assert {:error, {:agent_plugin_manifest_unreadable, "broken", :enoent}} =
             SourceReader.read_trusted_agent_plugins(roots: [root])
  end

  test "a directory at the manifest file path is not a Plugin manifest" do
    root = tmp_root!("manifest-is-directory")
    manifest_dir = Path.join([root, "agent-plugins", "not-a-plugin", ".codex-plugin"])
    File.mkdir_p!(Path.join(manifest_dir, "plugin.json"))

    assert {:ok, []} = SourceReader.read_trusted_agent_plugins(roots: [root])

    File.rmdir!(Path.join(manifest_dir, "plugin.json"))
    File.ln_s!(".", Path.join(manifest_dir, "plugin.json"))
    assert {:ok, []} = SourceReader.read_trusted_agent_plugins(roots: [root])
  end

  test "a file at the manifest directory path is not a Plugin package" do
    root = tmp_root!("manifest-parent-is-file")
    plugin_root = Path.join([root, "agent-plugins", "not-a-plugin"])
    File.mkdir_p!(plugin_root)
    path = Path.join(plugin_root, ".codex-plugin")
    File.write!(path, "Not a manifest directory")

    assert {:ok, []} = SourceReader.read_trusted_agent_plugins(roots: [root])

    File.rm!(path)
    File.write!(Path.join(plugin_root, "metadata.txt"), "Not a manifest directory")
    File.ln_s!("metadata.txt", path)
    assert {:ok, []} = SourceReader.read_trusted_agent_plugins(roots: [root])
  end

  test "a broken Plugin root link is not a removed root" do
    root = tmp_root!("broken-root")
    File.ln_s!("missing", Path.join(root, "agent-plugins"))

    assert {:error, {:agent_plugin_root_unreadable, _, :enoent}} =
             SourceReader.read_trusted_agent_plugins(roots: [root])
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
