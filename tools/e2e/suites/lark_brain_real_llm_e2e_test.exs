defmodule Ankole.E2E.LarkBrainRealLLME2ETest do
  @moduledoc """
  Dedicated real-model acceptance for `internals/docs/BrainV2.zh.md`.

  This suite is intentionally excluded from the normal gate and `--all`.
  Run it with `tools/e2e/run --brain-real-llm`.
  """

  use Ankole.DataCase, async: false

  import Ankole.E2E.Harness
  import Ankole.E2E.Scenarios.BrainRealLLM

  alias Ankole.Repo

  @moduletag :real_llm
  @moduletag :brain_real_llm
  @moduletag timeout: 1_800_000
  @moduletag ownership_timeout: 1_800_000

  @tag :brain_postgres_prerequisites
  test "Brain PostgreSQL runtime prerequisites are active" do
    assert %{rows: [[server_version_num]]} = Repo.query!("SHOW server_version_num")
    assert String.to_integer(server_version_num) >= 180_000

    assert %{rows: extension_rows} =
             Repo.query!(
               "SELECT extname FROM pg_extension WHERE extname IN ('pg_search', 'vector')"
             )

    assert extension_rows |> List.flatten() |> Enum.sort() == ["pg_search", "vector"]

    assert %{rows: [[preloaded]]} = Repo.query!("SHOW shared_preload_libraries")

    assert preloaded
           |> String.split(",", trim: true)
           |> Enum.map(&String.trim/1)
           |> Enum.member?("pg_search")
  end

  @tag :brain_preference_evolution
  test "preference evolution leaves one current fact and no stale search hit" do
    ctx = start_brain_stack!()

    assert %{entry: _entry, turns: [_created, _corrected, _recalled]} =
             run_preference_evolution(ctx)
  end

  @tag :brain_rumor_to_announcement
  test "official announcement replaces the unverified rumor with a new citation" do
    ctx = start_brain_stack!()
    assert %{entry: _entry, turns: [_rumor, _announcement]} = run_rumor_to_announcement(ctx)
  end

  @tag :brain_dm_isolation
  test "DM knowledge stays private while shared knowledge is readable across agents" do
    ctx = start_brain_stack!()
    assert %{private: _private, shared: _shared} = run_dm_isolation(ctx)
  end

  @tag :brain_unified_recall_ranking
  test "an exact chat error ranks before old weak knowledge" do
    ctx = start_brain_stack!()

    assert %{chat_source: _source, weak_entry: _entry, turn: _turn} =
             run_unified_recall_ranking(ctx)
  end

  @tag :brain_episode_paraphrase
  test "a paraphrase recalls an embedded episode and its source messages" do
    ctx = start_brain_stack!()
    assert %{episode: _episode, sources: [_ | _], turn: _turn} = run_episode_paraphrase(ctx)
  end

  @tag :brain_dreaming_idempotence
  test "dreaming consolidates repeated material and a second run writes nothing" do
    ctx = start_brain_stack!()

    assert %{
             first_run: %{status: :completed},
             second_run: %{status: :no_new_material},
             blocks: [_ | _]
           } = run_dreaming_idempotence(ctx)
  end

  @tag :brain_dreaming_convergence
  test "dreaming rewrites one topic and records its explicit linked relation" do
    ctx = start_brain_stack!()

    assert %{project: _project, organization: _organization, relation: _relation} =
             run_dreaming_convergence(ctx)
  end

  @tag :brain_source_mirror_sync
  test "a connector revision replaces a read-only mirror and deletion withdraws it" do
    ctx = start_brain_stack!()
    assert %{source: _source, first: _first, second: _second} = run_source_mirror_sync(ctx)
  end

  @tag :brain_human_review
  test "human review begins with health checks and applies the oral decision" do
    ctx = start_brain_stack!()
    assert %{audit: _audit, turns: [_seeded, _review, _decided]} = run_human_review(ctx)
  end

  @tag :brain_skill_learning
  test "skill correction survives into the next skill load" do
    ctx = start_brain_stack!()
    assert %{overlay: overlay, turns: [_learned, _loaded]} = run_skill_learning(ctx)
    assert overlay =~ "REVIEW_OPEN_SOURCE_FIRST"
  end

  @tag :brain_retraction
  test "recall deletes cited blocks, preserves uncited blocks, and keeps recovery audit" do
    ctx = start_brain_stack!()

    assert %{
             deleted_block: _deleted,
             preserved_block: _preserved,
             audit: _audit
           } = run_retraction(ctx)
  end

  defp start_brain_stack! do
    start_worker_e2e_stack!(
      real_llm_api_key: openrouter_api_key!(),
      worker_prefix: "brain-real-llm"
    )
    |> prepare_brain_real_llm!()
  end
end
