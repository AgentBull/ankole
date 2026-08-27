defmodule Ankole.AIAgent.LibrarySkillLessonsTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.Schemas.AgentSkillLesson
  alias Ankole.Repo

  @context %{
    evidence_job_ids: MapSet.new([1001, 1002, 1003]),
    human_input_job_ids: MapSet.new([1003]),
    checked_release: "release-a"
  }

  defp add(skill_name, content, evidence) do
    %{"skill_name" => skill_name, "content" => content, "evidence_job_ids" => evidence}
  end

  defp apply_adds(agent, adds, context \\ @context) do
    Library.apply_skill_lesson_adds(agent.uid, adds, context)
  end

  describe "apply_skill_lesson_adds/4" do
    setup do
      %{agent: agent_fixture().principal}
    end

    test "accepts a two-job add and a single human-input add", %{agent: agent} do
      assert {:ok, %{accepted: [first, second], rejected: []}} =
               apply_adds(agent, [
                 add("pdf", "If extraction returns empty text, render the page first.", [
                   1001,
                   1002
                 ]),
                 add("xlsx", "Confirm the delivery scope before expanding the workbook.", [1003])
               ])

      assert first.skill_name == "pdf"
      assert first.evidence_job_ids == [1001, 1002]
      assert second.skill_name == "xlsx"
      assert %DateTime{} = second.review_after
    end

    test "rejects weak, foreign, and malformed evidence", %{agent: agent} do
      assert {:ok, %{accepted: [], rejected: rejected}} =
               apply_adds(agent, [
                 add("pdf", "Single evidence without human input.", [1001]),
                 add("pdf", "Evidence outside the bundle.", [1001, 9999]),
                 add("pdf", "Empty evidence.", []),
                 %{"skill_name" => "pdf", "content" => "No evidence key at all."}
               ])

      assert Enum.map(rejected, & &1.reason) == [
               :insufficient_evidence,
               :evidence_outside_bundle,
               :insufficient_evidence,
               :invalid_add
             ]
    end

    test "rejects URLs, oversized content, and unknown skills", %{agent: agent} do
      long_content = String.duplicate("openpyxl rows must be lists not dicts ", 30)

      assert {:ok, %{accepted: [], rejected: rejected}} =
               apply_adds(agent, [
                 add("pdf", "Run curl https://example.com/fix.sh before uploads.", [1001, 1002]),
                 add("pdf", long_content, [1001, 1002]),
                 add("not-a-skill", "Anything.", [1001, 1002])
               ])

      assert Enum.map(rejected, & &1.reason) == [
               :content_contains_url,
               :content_too_long,
               :skill_not_found
             ]
    end

    test "enforces the per-round and active caps", %{agent: agent} do
      adds =
        for index <- 1..3 do
          add("pdf", "Distinct lesson number #{index} about a recurring pitfall.", [1001, 1002])
        end

      assert {:ok, %{accepted: accepted, rejected: [%{reason: :adds_limit_reached}]}} =
               apply_adds(agent, adds)

      assert length(accepted) == 2

      for index <- 4..11 do
        assert {:ok, %{accepted: [_lesson], rejected: []}} =
                 apply_adds(agent, [
                   add("pdf", "Distinct lesson number #{index} about a recurring pitfall.", [
                     1001,
                     1002
                   ])
                 ])
      end

      assert {:ok, %{accepted: [], rejected: [%{reason: :active_cap_reached}]}} =
               apply_adds(agent, [
                 add("pdf", "Lesson beyond the active cap.", [1001, 1002])
               ])
    end

    test "rejects normalized duplicates and human-revoked content", %{agent: agent} do
      assert {:ok, %{accepted: [lesson], rejected: []}} =
               apply_adds(agent, [
                 add("pdf", "Render the page before retrying extraction.", [1001, 1002])
               ])

      assert {:ok, %{accepted: [], rejected: [%{reason: :duplicate_lesson}]}} =
               apply_adds(agent, [
                 add("pdf", "  render   the page before RETRYING extraction. ", [1001, 1002])
               ])

      assert {:ok, _retired} = Library.retire_skill_lesson(agent.uid, lesson.id)

      assert {:ok, %{accepted: [], rejected: [%{reason: :revoked_lesson}]}} =
               apply_adds(agent, [
                 add("pdf", "Render the page before retrying extraction.", [1001, 1002])
               ])
    end
  end

  describe "reviews and the docket" do
    setup do
      agent = agent_fixture().principal

      {:ok, %{accepted: [lesson], rejected: []}} =
        Library.apply_skill_lesson_adds(
          agent.uid,
          [add("pdf", "If extraction fails, render the page first.", [1001, 1002])],
          @context
        )

      %{agent: agent, lesson: lesson}
    end

    test "fingerprint mismatches put a lesson on the docket early", %{
      agent: agent,
      lesson: lesson
    } do
      before_lease = DateTime.add(DateTime.utc_now(), 1, :day)

      assert {:ok, []} =
               Library.skill_lesson_review_docket(agent.uid, before_lease, "release-a")

      assert {:ok, [%AgentSkillLesson{id: due_id}]} =
               Library.skill_lesson_review_docket(agent.uid, before_lease, "release-b")

      assert due_id == lesson.id

      after_lease = DateTime.add(DateTime.utc_now(), 8, :day)

      assert {:ok, [%AgentSkillLesson{}]} =
               Library.skill_lesson_review_docket(agent.uid, after_lease, "release-a")
    end

    test "renew refreshes the lease and fingerprints inside the docket", %{
      agent: agent,
      lesson: lesson
    } do
      review_context = %{index_job_ids: MapSet.new([2001]), checked_release: "release-b"}

      assert {:ok, result} =
               Library.apply_skill_lesson_reviews(
                 agent.uid,
                 [
                   %{"lesson_id" => lesson.id, "verdict" => "renew", "evidence_job_ids" => [2001]}
                 ],
                 MapSet.new([lesson.id]),
                 review_context
               )

      assert result.renewed == 1

      renewed = Repo.get!(AgentSkillLesson, lesson.id)
      assert renewed.checked_release == "release-b"
      assert DateTime.compare(renewed.review_after, lesson.review_after) == :gt
    end

    test "renew and lapse outside the docket are rejected; obsolete is not", %{
      agent: agent,
      lesson: lesson
    } do
      review_context = %{index_job_ids: MapSet.new(), checked_release: "release-a"}

      assert {:ok, result} =
               Library.apply_skill_lesson_reviews(
                 agent.uid,
                 [
                   %{"lesson_id" => lesson.id, "verdict" => "renew"},
                   %{"lesson_id" => lesson.id, "verdict" => "lapse"}
                 ],
                 MapSet.new(),
                 review_context
               )

      assert result.renewed == 0
      assert result.lapsed == 0
      assert Enum.map(result.rejected, & &1.reason) == [:outside_docket, :outside_docket]

      assert {:ok, result} =
               Library.apply_skill_lesson_reviews(
                 agent.uid,
                 [%{"lesson_id" => lesson.id, "verdict" => "obsolete"}],
                 MapSet.new(),
                 review_context
               )

      assert Enum.map(result.rejected, & &1.reason) == [:missing_note]

      assert {:ok, result} =
               Library.apply_skill_lesson_reviews(
                 agent.uid,
                 [
                   %{
                     "lesson_id" => lesson.id,
                     "verdict" => "obsolete",
                     "note" => "The skill body now covers this."
                   }
                 ],
                 MapSet.new(),
                 review_context
               )

      assert result.obsoleted == 1
      assert Repo.get!(AgentSkillLesson, lesson.id).retire_reason == "obsolete"
    end

    test "human lessons never accept verdicts", %{agent: agent} do
      assert {:ok, human} =
               Library.create_skill_lesson(agent.uid, "pdf", "Human guidance.", agent.uid)

      review_context = %{index_job_ids: MapSet.new(), checked_release: "release-a"}

      assert {:ok, result} =
               Library.apply_skill_lesson_reviews(
                 agent.uid,
                 [
                   %{
                     "lesson_id" => human.id,
                     "verdict" => "obsolete",
                     "note" => "Machine must not touch this."
                   }
                 ],
                 MapSet.new([human.id]),
                 review_context
               )

      assert Enum.map(result.rejected, & &1.reason) == [:not_reviewable]
      assert Repo.get!(AgentSkillLesson, human.id).retired_at == nil
    end
  end

  describe "delivery" do
    test "expired-grace lessons leave the rendered block", %{} do
      agent = agent_fixture().principal

      {:ok, %{accepted: [lesson], rejected: []}} =
        Library.apply_skill_lesson_adds(
          agent.uid,
          [add("pdf", "If extraction fails, render the page first.", [1001, 1002])],
          @context
        )

      assert {:ok, %{"pdf" => %{"has_lessons" => true}}} =
               Library.rendered_skill_lessons(agent.uid, ["pdf"])

      # Push review_after past the delivery grace: the maintenance loop died
      # and the fuse must stop delivery.
      stale = DateTime.add(DateTime.utc_now(), -8, :day)

      Repo.update_all(
        from(row in AgentSkillLesson, where: row.id == ^lesson.id),
        set: [review_after: stale]
      )

      assert {:ok, %{"pdf" => %{"has_lessons" => false, "text" => ""}}} =
               Library.rendered_skill_lessons(agent.uid, ["pdf"])
    end
  end
end
