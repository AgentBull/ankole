defmodule Ankole.AIAgent.LarkSkillSourcesTest do
  use ExUnit.Case, async: true

  @agent_plugins_root Path.expand("../../../../library/agent-plugins", __DIR__)
  @lark_skills_root Path.join(@agent_plugins_root, "lark/skills")
  @lark_skills ~w(lark-im lark-office-suite lark-oa)

  test "the Lark Agent Plugin owns exactly three default-on member Skills without user auth paths" do
    actual_lark_skills =
      @lark_skills_root
      |> Path.join("*/SKILL.md")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
      |> Enum.sort()

    assert actual_lark_skills == Enum.sort(@lark_skills)

    for skill_name <- @lark_skills do
      skill_root = Path.join(@lark_skills_root, skill_name)
      skill_file = File.read!(Path.join(skill_root, "SKILL.md"))

      assert skill_file =~ "name: #{skill_name}"
      assert skill_file =~ "default_enabled: true"
      refute skill_file =~ "ankole-runtime: background_job"
      assert File.exists?(Path.join(skill_root, "THIRD-PARTY-NOTICES.txt"))

      combined_source =
        skill_root
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map_join("\n", &File.read!/1)

      refute combined_source =~ "--as user"
      refute combined_source =~ "auth login"
      refute combined_source =~ "config init"
      refute combined_source =~ "AgentMember"
    end
  end

  test "the Agent Computer image validates bot examples at build time" do
    agent_computer_root = Path.expand("../../../../agent_computer", __DIR__)
    dockerfile = File.read!(Path.join(agent_computer_root, "Dockerfile"))

    assert dockerfile =~
             "RUN bun app/agent_computer/src/validation/lark-skill-examples.ts app/library/agent-plugins/lark/skills"
  end

  test "local Office skills route Lark cloud resources away from OfficeCLI" do
    docx = File.read!(Path.join([@agent_plugins_root, "office", "skills", "docx", "SKILL.md"]))
    xlsx = File.read!(Path.join([@agent_plugins_root, "office", "skills", "xlsx", "SKILL.md"]))

    assert docx =~ "lark-office-suite"
    assert xlsx =~ "lark-office-suite"
  end
end
