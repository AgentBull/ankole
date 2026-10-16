defmodule Ankole.AIAgent.Library.SourceReaderTest do
  use ExUnit.Case, async: true

  alias Ankole.AIAgent.Library.SourceReader

  setup do
    root =
      Path.join(System.tmp_dir!(), "ankole-skill-reader-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "lists only Skill directories and keeps readable directory and file links", %{root: root} do
    File.mkdir_p!(Path.join(root, "actual"))
    File.write!(Path.join(root, "actual/SKILL.md"), "Skill body")
    File.mkdir_p!(Path.join(root, "empty"))
    File.write!(Path.join(root, "README.md"), "Not a Skill")
    File.ln_s!("actual", Path.join(root, "linked"))
    File.mkdir_p!(Path.join(root, "linked-file"))
    File.ln_s!("../actual/SKILL.md", Path.join(root, "linked-file/SKILL.md"))
    File.mkdir_p!(Path.join(root, "not-a-file/SKILL.md"))
    File.mkdir_p!(Path.join(root, "linked-directory"))
    File.ln_s!("../actual", Path.join(root, "linked-directory/SKILL.md"))

    assert {:ok, ["actual", "linked", "linked-file"]} = SourceReader.list_skill_directories(root)
  end

  test "an unreadable entry cannot become an empty Skill inventory", %{root: root} do
    File.ln_s!("missing", Path.join(root, "broken"))

    assert {:error, :enoent} = SourceReader.list_skill_directories(root)
  end

  test "a broken Skill file link is an error rather than an absent Skill", %{root: root} do
    File.mkdir_p!(Path.join(root, "broken"))
    File.ln_s!("missing", Path.join(root, "broken/SKILL.md"))

    assert {:error, :enoent} = SourceReader.list_skill_directories(root)
    assert {:error, :enoent} = SourceReader.read_skill_source(root, "library", "broken")
  end
end
