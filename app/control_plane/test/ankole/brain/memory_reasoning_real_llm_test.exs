defmodule Ankole.Brain.MemoryReasoningRealLLMTest do
  @moduledoc """
  Stateless real-model checks of Dreaming evidence handling, through its
  production prompts, AIGateway, and PostgreSQL write contracts.
  """
  use Ankole.AIGatewayCase

  alias Ankole.AppConfigure
  alias Ankole.Brain.{Calibration, Claims, Objects, Patterns, SchemaPacks}
  alias Ankole.Brain.Schemas.Claim

  @moduletag :real_llm
  @moduletag timeout: 300_000
  @model System.get_env("ANKOLE_REAL_LLM_MODEL", "z-ai/glm-5.3-flash")

  setup do
    allow_cache_database_access()
    AppConfigure.Cache.clear_for_test()
    on_exit(fn -> AppConfigure.Cache.clear_for_test() end)
    {:ok, _result} = SchemaPacks.install_packs([])
    api_key = System.fetch_env!("OPEN_ROUTER_API_KEY")

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "memory-reasoning-real",
        provider_kind: "openrouter",
        credential_pool: %{"entries" => [%{"label" => "Test", "api_key" => api_key}]}
      })

    agent_uid = configure_brain_maintainer_profile!("heavy", "memory-reasoning-real", @model)
    %{agent_uid: agent_uid}
  end

  for {evidence, expected} <- [
        {"On 2020-01-01 the team planned to deliver the report by 2020-01-02.", "unresolvable"},
        {"The recipient confirmed receipt of the final report on 2020-01-02 at 09:00 UTC.",
         "correct"}
      ] do
    @evidence evidence
    @expected expected
    test "grades a delivery prediction as #{expected} from its outcome evidence", %{
      agent_uid: uid
    } do
      slug = "projects/report-delivery"
      create_page!(slug)
      write_fact!(slug, @evidence, "delivery record", uid)

      {:ok, take} =
        Claims.write_take(
          %{
            object_slug: slug,
            claim: "The recipient will receive the final report by the end of 2020-01-02 UTC.",
            kind: "prediction",
            holder: "agents/" <> uid,
            audience_scope: "world",
            weight: 0.8,
            since_date: "2020-01-01",
            until_date: "2020-01-02",
            provenance: "prediction recorded on 2020-01-01"
          },
          uid,
          embed: false
        )

      assert %{status: :ok, graded: 1, candidates: 1} = Calibration.grade_takes()
      assert Repo.get!(Claim, take.id).graded_quality == @expected
    end
  end

  test "does not turn three copies of one old report into a recurring pattern", %{agent_uid: uid} do
    reports = [
      "A version 1.0 upgrade removes stored memories.",
      "The version 1.0 upgrade deletes existing memory records.",
      "Old memories are deleted when upgrading to version 1.0."
    ]

    for {report, index} <- Enum.with_index(reports, 1) do
      slug = "projects/repeated-report-#{index}"
      create_page!(slug)

      write_fact!(
        slug,
        report,
        "release-note-2020-01-01, section: version 1.0 migration",
        uid
      )
    end

    assert %{status: :ok, pages: 0, buckets: 1, errors: []} = Patterns.run()
  end

  test "retains a recurring problem supported by independent project records", %{agent_uid: uid} do
    for index <- 1..3 do
      slug = "projects/delivery-#{index}"
      create_page!(slug)

      write_fact!(
        slug,
        "Project #{index}'s report was rejected because it omitted the original research question and the agreed scope.",
        "project-#{index} delivery review, 2020-01-0#{index}",
        uid
      )
    end

    assert %{status: :ok, pages: pages, buckets: 1, errors: []} = Patterns.run()
    assert pages > 0
  end

  defp create_page!(slug) do
    {:ok, _page} = Objects.create_object(%{slug: slug, type: "project", title: slug}, :system)
  end

  defp write_fact!(slug, text, provenance, uid) do
    {:ok, _result} =
      Claims.write_fact(
        %{
          object_slug: slug,
          claim: text,
          kind: "event",
          holder: "world",
          audience_scope: "world",
          confidence: 0.75,
          notability: "high",
          valid_from: ~U[2020-01-01 00:00:00.000000Z],
          provenance: provenance
        },
        uid,
        embed: false
      )
  end
end
