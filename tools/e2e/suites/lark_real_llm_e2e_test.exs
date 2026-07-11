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
  alias Ankole.AIAgent.CodexAccounts
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

  @tag timeout: 900_000
  @tag ownership_timeout: 900_000
  @tag :real_llm
  @tag :browser_tool
  test "real OpenRouter LLM completes a browser-only OpenRouter pricing task" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())

    result = run_real_lark_openrouter_browser_turn(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      result.reply,
      "ANKOLE_OPENROUTER_BROWSER_OK",
      :reply,
      "om_real_openrouter_browser_1"
    )
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  @tag :real_llm
  @tag :browser_tool
  @tag :web_fetch
  test "real OpenRouter LLM uses web_fetch" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())

    result = run_real_lark_web_fetch_turn(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      result.reply,
      "ANKOLE_WEB_FETCH_LIVE_OK",
      :reply,
      "om_real_web_fetch_local_browser_1"
    )
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  @tag :real_llm
  @tag :terminal_tools_real_llm
  test "real OpenRouter LLM completes a multi-step terminal tools task" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())

    result = run_real_lark_terminal_tools_turn(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      result.reply,
      "ANKOLE_TERMINAL_TOOLS_REAL_OK",
      :reply,
      "om_real_terminal_tools_1"
    )
  end

  @tag timeout: 1_800_000
  @tag ownership_timeout: 1_800_000
  @tag :real_llm
  @tag :codex_todolist_real_llm
  test "real OpenRouter model delegates and verifies a Vite React todolist task" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())

    result = run_real_lark_codex_todolist_turn(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      result.reply,
      "ANKOLE_CODEX_TODOLIST_REAL_OK",
      :reply,
      "om_real_codex_todolist_1"
    )
  end

  @tag timeout: 1_800_000
  @tag ownership_timeout: 1_800_000
  @tag :real_llm
  @tag :codex_subscription_real_llm
  test "real ChatGPT subscription account completes the delegated Codex task" do
    auth_json = File.read!(Path.expand("~/.codex/auth.json"))
    %{"tokens" => %{"account_id" => account_id}} = Ankole.JSON.decode!(auth_json)

    assert {:ok, account} =
             CodexAccounts.create_account(%{
               "name" => "Real subscription #{String.slice(account_id, 0, 8)}",
               "auth_json" => auth_json
             })

    ctx =
      start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())
      |> Map.put(:codex_account_id, account.account_id)

    result = run_real_lark_codex_todolist_turn(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      result.reply,
      "ANKOLE_CODEX_TODOLIST_REAL_OK",
      :reply,
      "om_real_codex_todolist_1"
    )

    assert {:ok, resolved} = CodexAccounts.resolve_auth(account.account_id)
    assert resolved.auth_hash == Ankole.Kernel.generic_hash(resolved.auth_json)
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  @tag :real_llm
  test "real OpenRouter LLM handles Lark post images and vision fallback" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())

    direct = run_real_lark_post_image_direct_vision_turn(ctx)
    direct_text = direct.reply.text || ""

    assert_lark_final_reply(
      ctx.fake_feishu,
      direct.reply,
      direct_text,
      :reply,
      "om_real_image_direct_1"
    )

    assert_vision_false_reply!(direct_text)

    fallback = run_real_lark_post_image_vision_fallback_turn(ctx)
    fallback_text = fallback.reply.text || ""

    assert_lark_final_reply(
      ctx.fake_feishu,
      fallback.reply,
      fallback_text,
      :reply,
      "om_real_image_fallback_1"
    )

    assert_vision_false_reply!(fallback_text)
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

  defp assert_vision_false_reply!(text) do
    normalized = String.downcase(text || "")

    assert String.contains?(normalized, "false"),
           "expected vision reply to say false, got: #{inspect(text)}"

    refute Regex.match?(~r/\btrue\b/, normalized),
           "expected vision reply not to say true, got: #{inspect(text)}"
  end
end
