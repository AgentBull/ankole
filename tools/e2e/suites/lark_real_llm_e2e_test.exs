defmodule Ankole.E2E.LarkRealLLME2ETest do
  @moduledoc """
  Real-provider smoke through the full chain: fake Feishu WS ingress, real
  Docker worker, real OpenRouter LLM, real outbox HTTP — plus AIGateway
  embedding and rerank against the real provider.

  Requires `ANKOLE_REAL_LLM_E2E=1` and an OpenRouter API key.
  """

  use Ankole.DataCase, async: false

  import Ankole.E2E.Harness
  import Ankole.E2E.Scenarios.DeepResearchRealLLM
  import Ankole.E2E.Scenarios.RealLLM
  import Ankole.E2E.Scenarios.SkillLesson

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job, as: BackgroundAgentJob
  alias Ankole.E2E.WaitHelpers
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery

  import Ecto.Query

  # Models are deliberately hardcoded (no env overrides): the suite gates a
  # known-good provider/model matrix, not arbitrary local configurations.
  @embedding_model "qwen/qwen3-embedding-4b"
  @rerank_model "qwen/qwen3-reranker-8b"
  @chatgpt_coding_model "gpt-5.6-sol"

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

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  @tag :real_llm
  @tag :web_fetch
  test "real OpenRouter LLM uses web_fetch" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())

    result = run_real_lark_web_fetch_turn(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      result.reply,
      "ANKOLE_WEB_FETCH_LIVE_OK",
      :reply,
      "om_real_web_fetch_rendered_fallback_1"
    )
  end

  @tag timeout: 900_000
  @tag ownership_timeout: 900_000
  @tag :real_llm
  @tag :skill_lessons
  test "real codex reflection distills seeded evidence into delivered skill lessons" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())

    %{lessons: lessons} = run_real_skill_lesson_reflection_loop(ctx)
    assert Enum.all?(lessons, &(&1.author_kind == "dreaming"))
  end

  @tag timeout: 900_000
  @tag ownership_timeout: 900_000
  @tag :real_llm
  @tag :skill_lessons
  test "a real codex background job recalls instance memory over the live RPC boundary" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())

    %{job: job} = run_real_job_brain_recall_turn(ctx)
    assert job.status == "succeeded"
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
  @tag :codex_pptx_skill_real_llm
  test "real OpenRouter parent runs the Office Agent Plugin and delivers a PPTX" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())

    result = run_real_lark_codex_pptx_skill_turn(ctx)

    assert result.job.status == "succeeded"
    assert result.outbox.status == :succeeded
    assert result.platform_message.msg_type == "file"
    assert result.outline =~ "2 slides"
    assert result.text =~ "Verified Handoff"
  end

  @tag timeout: 3_600_000
  @tag ownership_timeout: 3_600_000
  @tag :real_llm
  @tag :deep_research_real_llm
  test "real parent Job flow runs Deep Research as a standard Codex Plugin" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())

    result = run_deep_research_plugin(ctx)

    assert result.report =~ "Aurora's approved budget is 10 units."
  end

  @tag timeout: 1_800_000
  @tag ownership_timeout: 1_800_000
  @tag :real_llm
  @tag :codex_subscription_main_real_llm
  test "real ChatGPT subscription drives the main Agent tool loop" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())
    provider_id = create_chatgpt_subscription_provider!()

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(ctx.agent.uid, "primary", %{
               provider_id: provider_id,
               model: @chatgpt_coding_model,
               provider_options: %{"reasoningEffort" => "high"}
             })

    result = run_real_lark_skill_tool_loop(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      result.reply,
      "ANKOLE_LARK_REAL_SKILL_OK",
      :reply,
      "om_real_skill_1"
    )
  end

  @tag timeout: 1_800_000
  @tag ownership_timeout: 1_800_000
  @tag :real_llm
  @tag :codex_subscription_real_llm
  test "real ChatGPT subscription runs Codex Tool Search and MCP code mode" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())
    provider_id = create_chatgpt_subscription_provider!()

    ctx =
      Map.merge(ctx, %{
        coding_provider_id: provider_id,
        coding_model: @chatgpt_coding_model,
        coding_provider_options: %{"reasoningEffort" => "high"}
      })

    result = run_real_lark_codex_ptc_mcp_turn(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      result.reply,
      "ANKOLE_CODEX_PTC_146_STARTED",
      :reply,
      "om_real_codex_ptc_mcp_1"
    )

    assert result.legacy_auth_absent
    assert {:ok, projection} = ProviderConfigs.get_provider(provider_id)
    assert [entry] = projection["credential_pool"]["entries"]
    assert entry["credential_present"]
    assert entry["account_id"]
    refute Map.has_key?(entry, "access_token")
    refute Map.has_key?(entry, "refresh_token")
    refute Map.has_key?(entry, "id_token")
  end

  @tag timeout: 1_800_000
  @tag ownership_timeout: 1_800_000
  @tag :real_llm
  @tag :codex_subscription_background_direct_real_llm
  test "real ChatGPT subscription completes a directly dispatched Background Agent Job" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())
    provider_id = create_chatgpt_subscription_provider!()

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(ctx.agent.uid, "coding", %{
               provider_id: provider_id,
               model: @chatgpt_coding_model,
               provider_options: %{"reasoningEffort" => "high"}
             })

    owner_session_id = "codex-background-direct-real"

    assert {:ok, owner_conversation} =
             Ankole.AIGateway.Conversations.ensure_conversation(ctx.agent.uid, owner_session_id)

    marker = "ANKOLE_CODEX_BACKGROUND_DIRECT_REAL_OK"

    assert {:ok, %{job: job, dispatch_event: dispatch_event}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => ctx.agent.uid,
               "owner_session_id" => owner_session_id,
               "source_tool_call_id" => "codex-background-direct-real",
               "title" => "Verify the direct Codex subscription path",
               "task" => "Do not call tools. Reply exactly #{marker}.",
               "metadata" => %{"owner_conversation_id" => owner_conversation.id},
               "reply_route" => %{
                 "binding_name" => ctx.primary_binding.name,
                 "signal_channel_id" => "oc_codex_background_direct_real",
                 "provider_thread_id" => "",
                 "source_entry_id" => "om_codex_background_direct_real"
               }
             })

    completed =
      wait_for_direct_background_job!(
        job.id,
        dispatch_event.id,
        WaitHelpers.deadline(600_000)
      )

    assert get_in(completed.result, ["output_text"]) =~ marker
    assert get_in(completed.metadata, ["codex_user_agent"]) =~ "codex_cli_rs/0.150.1 "

    legacy_auth_path =
      Path.join([ctx.container.agents_root, ctx.agent.uid, ".codex", "auth.json"])

    refute File.exists?(legacy_auth_path)
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

    assert {:ok, embedding_response} =
             AIGateway.create_embeddings(ctx.agent.uid, %{
               "model" => "#{ctx.provider_id}/#{@embedding_model}",
               "input" => ["ankole gateway e2e query", "ankole gateway e2e passage"]
             })

    embedding_data = Map.fetch!(embedding_response.body, "data")
    assert length(embedding_data) == 2
    assert embedding_data |> hd() |> Map.fetch!("embedding") |> length() > 0

    assert {:ok, rerank_response} =
             AIGateway.create_rerank(ctx.agent.uid, %{
               "model" => "#{ctx.provider_id}/#{@rerank_model}",
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

  defp create_chatgpt_subscription_provider! do
    provider_id = "chatgpt-subscription-real-#{Ecto.UUID.generate()}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "chatgpt_subscription",
               credential_pool: %{
                 "entries" => [chatgpt_subscription_credential!()]
               }
             })

    provider_id
  end

  defp wait_for_direct_background_job!(job_id, dispatch_event_id, deadline) do
    case WaitHelpers.wait_until(deadline, fn ->
           case Repo.get!(BackgroundAgentJob, job_id) do
             %BackgroundAgentJob{status: "succeeded"} = job ->
               job

             %BackgroundAgentJob{status: status} = job when status in ["failed", "stopped"] ->
               flunk("""
               direct real Codex Background Agent Job ended as #{status}.
               error=#{inspect(job.error, printable_limit: 4_000)}
               """)

             %BackgroundAgentJob{} ->
               maybe_dispatch_direct_job_event(dispatch_event_id)
               nil
           end
         end) do
      {:ok, %BackgroundAgentJob{} = job} ->
        job

      :timeout ->
        job = Repo.get!(BackgroundAgentJob, job_id)

        flunk("""
        direct real Codex Background Agent Job timed out.
        status=#{job.status}
        error=#{inspect(job.error, printable_limit: 4_000)}
        """)
    end
  end

  defp maybe_dispatch_direct_job_event(dispatch_event_id) do
    event = Repo.get!(ActorEvent, dispatch_event_id)

    live_delivery? =
      Repo.exists?(
        from(delivery in ActorEventDelivery,
          where: delivery.actor_event_id == ^dispatch_event_id,
          where: delivery.state in ^ActorEventDelivery.live_states()
        )
      )

    now = DateTime.utc_now(:microsecond)

    if is_nil(event.completed_at) and not live_delivery? and
         DateTime.compare(event.available_at, now) != :gt do
      assert {:ok, _result} = process_ready_event_for_actor!(event, now)
    end

    :ok
  end

  defp assert_vision_false_reply!(text) do
    normalized = String.downcase(text || "")

    assert String.contains?(normalized, "false"),
           "expected vision reply to say false, got: #{inspect(text)}"

    refute Regex.match?(~r/\btrue\b/, normalized),
           "expected vision reply not to say true, got: #{inspect(text)}"
  end

  defp chatgpt_subscription_credential! do
    auth_json =
      System.get_env("ANKOLE_CHATGPT_AUTH_JSON") ||
        raise "ANKOLE_CHATGPT_AUTH_JSON is required for the ChatGPT subscription real LLM test"

    auth = Ankole.JSON.decode!(auth_json)
    tokens = Map.fetch!(auth, "tokens")

    %{
      "id" => "real-subscription",
      "label" => "Real ChatGPT subscription",
      "source" => "real_e2e_fixture",
      "access_token" => Map.fetch!(tokens, "access_token"),
      "refresh_token" => Map.fetch!(tokens, "refresh_token"),
      "id_token" => Map.fetch!(tokens, "id_token"),
      "account_id" => Map.fetch!(tokens, "account_id"),
      "last_refresh" => Map.get(auth, "last_refresh"),
      "auth_type" => "oauth"
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end
