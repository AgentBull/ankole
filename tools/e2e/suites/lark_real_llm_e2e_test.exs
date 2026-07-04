defmodule Ankole.E2E.LarkRealLLME2ETest do
  @moduledoc """
  Real-provider smoke through the full chain: fake Feishu WS ingress, real
  Docker worker, real OpenRouter LLM, real outbox HTTP — plus AIGateway
  embedding and rerank against the real provider.

  Requires `ANKOLE_REAL_LLM_E2E=1` and an OpenRouter API key.
  """

  use Ankole.DataCase, async: false

  import Ankole.E2E.Harness
  import Ankole.E2E.Scenarios.RealLLM

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway

  # Models are deliberately hardcoded (no env overrides): the suite gates a
  # known-good provider/model matrix, not arbitrary local configurations.
  @embedding_model "perplexity/pplx-embed-v1-0.6b"
  @rerank_model "cohere/rerank-4-fast"

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  @tag :real_llm
  test "real OpenRouter LLM drives direct and skill tool-loop turns over Lark" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())

    direct = run_real_lark_direct_turn(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      direct.reply,
      "ANKOLE_LARK_REAL_OK",
      :reply,
      "om_real_1"
    )

    skill = run_real_lark_skill_tool_loop(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      skill.reply,
      "ANKOLE_LARK_REAL_SKILL_OK",
      :reply,
      "om_real_skill_1"
    )
  end

  @tag timeout: 300_000
  @tag ownership_timeout: 300_000
  @tag :real_llm
  test "AIGateway embedding and rerank reach the real provider" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!(), worker: false)

    for {profile, model} <- [{"embedding", @embedding_model}, {"rerank", @rerank_model}] do
      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(ctx.agent.uid, profile, %{
                 provider_id: ctx.provider_id,
                 model: model,
                 provider_options: %{}
               })
    end

    assert {:ok, embedding_response} =
             AIGateway.create_embeddings(ctx.agent.uid, %{
               "model" => "embedding.default",
               "input" => ["ankole gateway e2e query", "ankole gateway e2e passage"]
             })

    embedding_data = Map.fetch!(embedding_response.body, "data")
    assert length(embedding_data) == 2
    assert embedding_data |> hd() |> Map.fetch!("embedding") |> length() > 0

    assert {:ok, rerank_response} =
             AIGateway.create_rerank(ctx.agent.uid, %{
               "model" => "rerank.default",
               "query" => "Which document is about Paris?",
               "documents" => [
                 "Paris is the capital of France.",
                 "Berlin is the capital of Germany.",
                 "The Pacific Ocean is very large."
               ],
               "top_n" => 2,
               "return_documents" => true
             })

    results = Map.fetch!(rerank_response.body, "results")
    assert length(results) >= 1
    assert Enum.all?(results, &is_integer(&1["index"]))
    assert Enum.all?(results, &is_number(&1["relevance_score"]))
  end
end
