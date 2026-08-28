defmodule Ankole.E2E.LarkWorkflowRealLLME2ETest do
  @moduledoc """
  Workflow lifecycle through the full chain: fake Feishu WS ingress, real
  Docker worker, real OpenRouter LLM, durable Workflow rows, and real outbox
  HTTP — fanout, sleep/wake, attention escalation, and Job delegation.

  Requires `ANKOLE_REAL_LLM_E2E=1` and an OpenRouter API key.
  """

  use Ankole.DataCase, async: false

  import Ankole.E2E.Harness
  import Ankole.E2E.Scenarios.WorkflowRealLLM

  alias Ankole.AIGateway
  alias Ankole.AppConfigure
  alias Ankole.Brain.Embeddings, as: BrainEmbeddings

  @embedding_model "qwen/qwen3-embedding-4b"
  @embedding_dimensions 2_560
  @rerank_model "qwen/qwen3-reranker-8b"

  @tag timeout: 1_800_000
  @tag ownership_timeout: 1_800_000
  @tag :real_llm
  test "real LLM drives Workflow fanout, sleep/wake, and attention over Lark" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())
    put_workflow_real_models!(ctx)

    fanout = run_real_workflow_fanout(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      fanout.reply,
      "ANKOLE_WF_FANOUT_OK",
      :reply,
      "om_wf_fanout_1"
    )

    sleep = run_real_workflow_sleep_timer(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      sleep.reply,
      "ANKOLE_WF_SLEEP_OK",
      :reply,
      "om_wf_sleep_1"
    )

    attention = run_real_workflow_attention(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      attention.reply,
      "ANKOLE_WF_ATT_OK",
      :reply,
      "om_wf_attention_1"
    )
  end

  @tag timeout: 1_800_000
  @tag ownership_timeout: 1_800_000
  @tag :real_llm
  test "real LLM Workflow task delegates a BackgroundAgentJob and wakes on its completion" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())
    put_workflow_real_models!(ctx)
    put_workflow_coding_models!(ctx)

    delegation = run_real_workflow_job_delegation(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      delegation.reply,
      "ANKOLE_WF_DELEGATE_OK",
      :reply,
      "om_wf_delegate_1"
    )
  end

  @tag timeout: 1_800_000
  @tag ownership_timeout: 1_800_000
  @tag :real_llm
  test "real LLM Workflow failure reply and task-failure null contract" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())
    put_workflow_real_models!(ctx)

    failed = run_real_workflow_failed_run_reply(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      failed.reply,
      "ANKOLE_WF_FAIL_OK",
      :reply,
      "om_wf_boom_1"
    )

    null_contract = run_real_workflow_task_failure_null(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      null_contract.reply,
      "ANKOLE_WF_NULL_OK",
      :reply,
      "om_wf_null_1"
    )
  end

  @tag timeout: 1_800_000
  @tag ownership_timeout: 1_800_000
  @tag :real_llm
  test "real LLM Workflow cancel stops a sleeping task and its delegated job" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())
    put_workflow_real_models!(ctx)
    put_workflow_coding_models!(ctx)

    cancel = run_real_workflow_cancel_with_delegated_job(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      cancel.reply,
      "ANKOLE_WF_CANCEL_OK",
      :reply,
      "om_wf_cancel_2"
    )
  end

  @tag timeout: 1_800_000
  @tag ownership_timeout: 1_800_000
  @tag :real_llm
  test "real LLM writes its own Workflow script that classifies tickers and delegates industry jobs" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())
    put_workflow_real_models!(ctx)
    put_workflow_coding_models!(ctx)

    orchestration = run_real_workflow_free_orchestration(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      orchestration.reply,
      "ANKOLE_WF_ORCH_OK",
      :reply,
      "om_wf_orch_1"
    )
  end

  @tag timeout: 300_000
  @tag ownership_timeout: 300_000
  @tag :real_llm
  test "Brain embedding and rerank reach OpenRouter with the qwen models" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!(), worker: false)

    assert {:ok, _value} =
             AppConfigure.put_global_by_key("brain.embedding_model", %{
               "provider_id" => ctx.provider_id,
               "model" => @embedding_model,
               "dimensions" => @embedding_dimensions
             })

    assert {:ok, _value} =
             AppConfigure.put_global_by_key("brain.rerank_model", %{
               "provider_id" => ctx.provider_id,
               "model" => @rerank_model
             })

    assert {:ok, {vectors, signature}} =
             BrainEmbeddings.embed_texts([
               "ankole workflow e2e query",
               "ankole workflow e2e passage"
             ])

    assert length(vectors) == 2

    assert vectors |> hd() |> Pgvector.to_list() |> length() ==
             BrainEmbeddings.physical_dimensions()

    assert is_binary(signature)

    # Recall's rerank path uses the same explicit provider/model selector. The
    # OpenRouter qwen3-reranker-8b upstream rate-limits aggressively, so a 429
    # asserts the gateway's rate-limit contract instead of the ranking.
    case AIGateway.create_rerank(BrainEmbeddings.subject_uid(), %{
           "model" => ctx.provider_id <> "/" <> @rerank_model,
           "query" => "Which document is about Paris?",
           "documents" => [
             "Paris is the capital of France.",
             "Berlin is the capital of Germany.",
             "The Pacific Ocean is very large."
           ],
           "top_n" => 3
         }) do
      {:ok, rerank_response} ->
        results = Map.fetch!(rerank_response.body, "results")
        assert length(results) >= 1
        assert Enum.all?(results, &is_integer(&1["index"]))
        assert Enum.all?(results, &is_number(&1["relevance_score"]))
        assert Enum.max_by(results, & &1["relevance_score"])["index"] == 0

      {:error, {:credential_pool_exhausted, details}} ->
        assert %{"retry_at" => retry_at, "statuses" => statuses} = details
        assert {:ok, _at, _offset} = DateTime.from_iso8601(retry_at)
        assert Enum.all?(statuses, fn {_id, status} -> status["last_error_code"] == "429" end)

      other ->
        flunk("unexpected rerank outcome: #{inspect(other, limit: 10)}")
    end
  end
end
