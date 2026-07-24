defmodule Ankole.AIAgent.LarkSkillSourcesTest do
  use ExUnit.Case, async: true

  @agent_plugins_root Path.expand("../../../../library/agent-plugins", __DIR__)
  @lark_skills_root Path.join(@agent_plugins_root, "lark/skills")
  @bot_lark_skills ~w(lark-im lark-office-suite lark-oa)
  @lark_skills ["lark-approvals" | @bot_lark_skills]

  test "the Lark Agent Plugin owns exactly four default-on member Skills" do
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
    end
  end

  test "bot member Skills do not add user authentication paths" do
    for skill_name <- @bot_lark_skills do
      combined_source = combined_skill_source(skill_name)

      refute combined_source =~ "--as user"
      refute combined_source =~ "auth login"
      refute combined_source =~ "config init"
      refute combined_source =~ "AgentMember"
    end
  end

  test "lark-approvals owns its per-human user authentication wrapper" do
    combined_source = combined_skill_source("lark-approvals")

    assert combined_source =~ "scripts/lark-approvals"
    assert combined_source =~ "auth login"
    assert combined_source =~ "--as user"
    assert combined_source =~ "ANKOLE_RUNTIME_LARK_PROFILE"
    refute combined_source =~ "AgentMember"
  end

  test "lark-approvals asks with clarify before it creates an approval" do
    skill_file = File.read!(Path.join([@lark_skills_root, "lark-approvals", "SKILL.md"]))

    initiate_reference =
      File.read!(
        Path.join([
          @lark_skills_root,
          "lark-approvals",
          "references",
          "lark-approval-initiate.md"
        ])
      )

    assert skill_file =~ "## 发起审批 SOP"
    assert skill_file =~ "调用 `clarify`"
    assert skill_file =~ "`同意并提交`"
    assert skill_file =~ "`取消申请`"
    assert skill_file =~ "自定义输入框"
    assert skill_file =~ "用户点击 `同意并提交` 之前，不得调用 `files upload` 或 `instances create`"

    assert initiate_reference =~ "`The user invoked a structured card action.`"
    assert initiate_reference =~ "`Selected value` 是 `同意并提交`"
    assert initiate_reference =~ "普通文字消息不是按钮选择"
    assert initiate_reference =~ "调用一次 `instances create --yes`"
    refute initiate_reference =~ "instances create --dry-run"

    for source <- [skill_file, initiate_reference] do
      refute source =~ "确认门"
      refute source =~ "两阶段"
      refute source =~ "确认稿"
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

  defp combined_skill_source(skill_name) do
    @lark_skills_root
    |> Path.join("#{skill_name}/**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map_join("\n", &File.read!/1)
  end
end
