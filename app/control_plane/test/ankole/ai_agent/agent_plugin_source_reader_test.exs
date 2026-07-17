defmodule Ankole.AIAgent.Library.AgentPlugins.SourceReaderTest do
  use ExUnit.Case, async: true

  alias Ankole.AIAgent.Library.AgentPlugins.SourceReader
  alias Ankole.Kernel, as: NativeKernel

  test "package hash is canonical over sorted POSIX relative paths" do
    root = tmp_root!("hash")
    File.mkdir_p!(Path.join(root, "nested"))
    File.write!(Path.join(root, "z.txt"), "last")
    File.write!(Path.join([root, "nested", "a.txt"]), <<0, 1, 2>>)

    canonical =
      IO.iodata_to_binary([
        "ankole-agent-plugin-v1\0",
        canonical_file("nested/a.txt", <<0, 1, 2>>),
        canonical_file("z.txt", "last")
      ])

    assert {:ok, hash} = SourceReader.package_hash(root)
    assert hash == NativeKernel.generic_hash(canonical)
  end

  test "package traversal rejects symlinks and files above the hard cap before reading" do
    symlink_root = tmp_root!("symlink")
    outside = Path.join(tmp_root!("outside"), "secret.txt")
    File.write!(outside, "secret")
    File.ln_s!(outside, Path.join(symlink_root, "linked.txt"))

    assert {:error, {:agent_plugin_symlink_rejected, "linked.txt"}} =
             SourceReader.package_hash(symlink_root)

    oversized_root = tmp_root!("oversized")
    oversized = Path.join(oversized_root, "large.bin")
    {:ok, io} = :file.open(String.to_charlist(oversized), [:write, :binary])
    {:ok, _offset} = :file.position(io, 8 * 1_024 * 1_024)
    :ok = :file.write(io, <<0>>)
    :ok = :file.close(io)

    assert {:error, {:agent_plugin_file_too_large, "large.bin", 8_388_608}} =
             SourceReader.package_hash(oversized_root)
  end

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
    assert length(conflict.content_hashes) == 1
    assert length(conflict.roots) == 2
  end

  test "the three trusted Agent Plugins are discovered from standard manifests" do
    root = Path.expand("../../../../library", __DIR__)

    assert {:ok, agent_plugins} = SourceReader.read_trusted_agent_plugins(roots: [root])
    assert Enum.map(agent_plugins, & &1.id) == ["deep-research", "lark", "office"]

    plugin = Enum.find(agent_plugins, &(&1.id == "deep-research"))

    assert plugin.id == "deep-research"
    assert plugin.version == "1.0.0"
    assert Enum.map(plugin.skills, & &1.name) == ["deep-research"]

    assert hd(plugin.skills).relative_path ==
             "agent-plugins/deep-research/skills/deep-research"

    assert hd(plugin.skills).metadata["skill_root"] == "library"
    assert hd(plugin.skills).metadata["agent_plugin_id"] == "deep-research"
    assert Enum.any?(plugin.files, &(&1.path == "workspace-template/AGENTS.md"))
    refute Map.has_key?(plugin, :ankole)
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

  defp canonical_file(path, content) do
    [
      <<byte_size(path)::unsigned-big-integer-size(32)>>,
      path,
      <<byte_size(content)::unsigned-big-integer-size(64)>>,
      content
    ]
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
