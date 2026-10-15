defmodule Ankole.Sessions.SkillsCatalogTest do
  use ExUnit.Case, async: true

  alias Ankole.BackgroundAgentJobs.RuntimeProjection
  alias Ankole.Sessions.Prompt

  defp skill(name, opts \\ []) do
    %{
      "skill_name" => name,
      "description" => Keyword.get(opts, :description, "Use #{name}."),
      "category" => Keyword.get(opts, :category),
      "agent_plugin_id" => Keyword.get(opts, :plugin),
      "metadata" => Keyword.get(opts, :metadata, %{})
    }
  end

  test "the index normalizes third-party text and drops names that are not addressable" do
    catalog =
      Prompt.skills_catalog(
        [
          skill("pdf-report",
            description: "Build\u202E weekly  reports\n with  charts",
            category: "docs\u200B"
          ),
          skill("evil\u200B-skill"),
          skill("   "),
          skill("hog", description: String.duplicate("words ", 3_000)),
          skill("lazy", metadata: %{"brain_recall_only" => true})
        ],
        :main
      )

    assert catalog =~ ~s(pdf-report: "Build weekly reports with charts")
    assert catalog =~ "docs:"
    refute catalog =~ "evil"
    refute catalog =~ "lazy"
    refute catalog =~ "Descriptions shortened"
    refute String.contains?(catalog, ["\u202E", "\u200B"])
  end

  test "each surface lists the Skills its runtime can load" do
    skills = [
      skill("any"),
      skill("main-only", metadata: %{"ankole-runtime" => "main"}),
      skill("job-only", metadata: %{"ankole-runtime" => "background_job"})
    ]

    main = Prompt.skills_catalog(skills, :main, true)
    assert main =~ "main-only"
    assert main =~ "job-only: [background task]"

    refute Prompt.skills_catalog(skills, :main, false) =~ "job-only"

    job = Prompt.skills_catalog(skills, :background_job)
    assert job =~ "any"
    assert job =~ "job-only"
    refute job =~ "main-only"
    refute job =~ "[background task]"
  end

  test "a large catalog keeps Skill identities before descriptions" do
    skills =
      for index <- 1..200,
          do:
            skill("skill-#{String.pad_leading("#{index}", 3, "0")}",
              description: "x" <> String.duplicate("y", 300)
            )

    catalog = Prompt.skills_catalog(skills, :main)
    assert catalog =~ "Skills list truncated to"
    assert String.length(catalog) <= 18_000
    assert catalog =~ "skill-001"
  end

  test "a Job selects its frozen choices that still exist, in a stable order" do
    projection = %{
      "skills" => [
        %{"id" => "zeta", "name" => "zeta"},
        %{"id" => "pdf", "name" => "pdf"},
        %{"id" => "alpha:member-b", "name" => "member-b", "agent_plugin_id" => "alpha"},
        %{"id" => "alpha:member-a", "name" => "member-a", "agent_plugin_id" => "alpha"},
        %{"id" => "removed-skill", "name" => "removed-skill"}
      ],
      "agent_plugins" => [
        %{"id" => "alpha", "skills" => ["member-b", "member-a"]},
        %{"id" => "removed-plugin", "skills" => ["gone"]}
      ]
    }

    member_a = skill("member-a", plugin: "alpha")
    member_b = skill("member-b", plugin: "alpha")

    skills = [
      skill("zeta"),
      member_b,
      skill("pdf"),
      skill("new"),
      member_a,
      skill("member-new", plugin: "alpha")
    ]

    plugins = [
      %{
        "id" => "alpha",
        "skills" => Enum.map(~w(member-new member-b member-a), &%{"catalog_name" => &1})
      }
    ]

    assert Enum.map(
             RuntimeProjection.selected_skills(projection, skills, plugins),
             & &1["skill_name"]
           ) ==
             ~w(pdf zeta member-a member-b)

    # A current plugin that lost a selected member is a broken catalog.
    assert_raise KeyError, fn ->
      RuntimeProjection.selected_skills(projection, skills -- [member_a], plugins)
    end
  end
end
