defmodule Ankole.E2E.LarkRealLLME2ETest do
  @moduledoc """
  Real-provider scenarios use fake Feishu WS ingress, the control-plane loop,
  real OpenRouter models, and Outbox HTTP. Computer scenarios use a real
  Docker Worker. Embedding and rerank use the real AIGateway provider.

  Requires `ANKOLE_REAL_LLM_E2E=1` and an OpenRouter API key.
  """

  use Ankole.DataCase, async: false

  import Ankole.E2E.Harness
  import Ankole.E2E.Scenarios.DeepResearchRealLLM
  import Ankole.E2E.Scenarios.RealLLM
  import Ankole.E2E.Scenarios.SkillLesson
  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_for_completed_final_reply: 3]

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job, as: BackgroundAgentJob
  alias Ankole.E2E.WaitHelpers
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker

  import Ecto.Query

  # Models are deliberately hardcoded (no env overrides): the suite gates a
  # known-good provider/model matrix, not arbitrary local configurations.
  @embedding_model "qwen/qwen3-embedding-4b"
  @rerank_model "qwen/qwen3-reranker-8b"
  @chatgpt_coding_model "gpt-5.6-sol"

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  @tag :real_llm
  @tag :deepseek_release_stories
  test "real OpenRouter LLM drives direct and skill tool-loop turns over Lark" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!(), worker: false)

    assert %AgentWorker{state: "absent", wanted_until: %DateTime{} = creation_request} =
             Repo.get!(AgentWorker, ctx.agent.uid)

    direct = run_real_lark_direct_turn(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      direct.reply,
      "ANKOLE_LARK_REAL_OK",
      :reply,
      "om_real_1"
    )

    assert %AgentWorker{state: "absent", wanted_until: ^creation_request} =
             Repo.get!(AgentWorker, ctx.agent.uid)

    skill = run_real_lark_skill_tool_loop(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      skill.reply,
      "ANKOLE_LARK_REAL_SKILL_OK",
      :reply,
      "om_real_skill_1"
    )

    assert %AgentWorker{state: "absent", wanted_until: ^creation_request} =
             Repo.get!(AgentWorker, ctx.agent.uid)
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  @tag :real_llm
  @tag :deepseek_clarification_flow
  test "real DeepSeek asks for a shipping choice and continues after an ordinary Lark reply" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!(), worker: false)
    process = %{agent_uid: ctx.agent.uid}
    reference = "SHIP#{100_000 + :rand.uniform(899_999)}"
    source_id = "om_real_clarification_request"
    answer_id = "om_real_clarification_answer"
    chat_id = "oc_real_clarification"

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_real_clarification_request",
               message_id: source_id,
               chat_id: chat_id,
               chat_type: "p2p",
               text: """
               Help me select shipping for fictional shipment #{reference}.
               I must choose the cost and delivery tradeoff; neither option is a default.
               Use clarify to ask me to choose between these two options, in this order:
               Ground: 5 days, $20. Air: 1 day, $80.
               Wait for my choice. Then confirm the selected method and shipment reference.
               This is an internal recommendation; do not place an order.
               """
             )

    input = actor_event_by_source_entry_id!(ctx.agent.uid, source_id)
    assert {:ok, _} = ensure_input_driver!(input, input.available_at)

    assert {:ok, _} =
             WaitHelpers.wait_for_actor_event_completed(process, input.id, deadline(180_000))

    messages = WaitHelpers.ai_messages_for_actor_event(input.id)
    assert [call] = tool_call_items(messages, "clarify")
    assert tool_result_succeeded?(messages, "clarify")

    assert [question_outbox] =
             Repo.all(
               from(o in Ankole.SignalsGateway.OutboxEntry,
                 where: o.source_actor_event_id == ^input.id,
                 where: o.delivery_class == :durable_ai_reply
               )
             )

    assert question_outbox.payload["metadata"]["source"] == "ai_gateway_clarify"
    [ground, air] = question_outbox.payload["interactive_output"]["choices"]
    assert String.downcase(ground["label"]) =~ "ground"
    assert String.downcase(air["label"]) =~ "air"
    interaction_id = "clarify:#{call["call_id"]}"
    checkpoint = Repo.reload!(input).reply_preview_checkpoint
    assert checkpoint["interactions"][interaction_id]["state"] == "pending"

    sent_question = dispatch_outbox_succeeded!(question_outbox)
    visible_question = platform_message!(ctx.fake_feishu, sent_question.created_source_entry_id)
    assert visible_question.sender == :bot
    assert visible_question.chat_id == chat_id
    assert visible_question.reply_to == source_id
    assert visible_question.text =~ ground["label"]
    assert visible_question.text =~ air["label"]

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_real_clarification_answer",
               message_id: answer_id,
               chat_id: chat_id,
               chat_type: "p2p",
               text: "1"
             )

    answer = actor_event_by_source_entry_id!(ctx.agent.uid, answer_id)
    assert answer.session_id == input.session_id
    assert answer.queue_sequence > input.queue_sequence
    assert {:ok, _} = ensure_input_driver!(answer, answer.available_at)

    assert {:ok, reply, _} =
             wait_for_completed_final_reply(process, answer.id, deadline(180_000))

    assert_lark_final_reply(ctx.fake_feishu, reply, reference, :reply, answer_id)
    assert String.downcase(reply.text) =~ "ground"
    assert_actor_event_completed!(answer.id)

    assert successful_tool_results(WaitHelpers.ai_messages_for_actor_event(answer.id), "clarify") ==
             []

    # Ordinary messages supersede the pending card; only a managed button or
    # form callback records an answered interaction.
    resolved = Repo.reload!(input).reply_preview_checkpoint["interactions"][interaction_id]
    assert resolved["state"] == "superseded"
    assert resolved["superseded_by_actor_event_id"] == answer.id
    assert is_binary(resolved["resolved_at"])

    assert [%Ankole.SignalsGateway.OutboxEntry{status: :succeeded} = final_outbox] =
             Repo.all(
               from(o in Ankole.SignalsGateway.OutboxEntry,
                 where: o.source_actor_event_id == ^answer.id,
                 where: o.delivery_class == :durable_ai_reply
               )
             )

    assert final_outbox.payload["metadata"]["source"] == "ai_gateway_final_reply"
    assert final_outbox.tenant_id == input.tenant_id
    assert reply.tenant_id == input.tenant_id

    assert Repo.get_by!(Ankole.SignalsGateway.OutboxEntry,
             agent_uid: sent_question.agent_uid,
             binding_name: sent_question.binding_name,
             outbound_key: sent_question.outbound_key
           ).status == :succeeded
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
  test "a real codex background job recalls instance memory through the hosted Brain tool" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())

    %{job: job} = run_real_job_brain_recall_turn(ctx)
    assert job.status == "succeeded"
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  @tag :real_llm
  @tag :terminal_tools_real_llm
  @tag :deepseek_release_stories
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
  @tag :deepseek_delivery_chaos
  test "real DeepSeek delivers pinned file bytes once after the platform accepts a send but its confirmation fails" do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())
    content = "HANDOFF_" <> Ecto.UUID.generate()
    source_id = "om_real_delivery_loss"

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_real_delivery_loss",
               message_id: source_id,
               chat_id: "oc_real_delivery_loss",
               chat_type: "p2p",
               text: """
               Create /workspace/handoff.txt with exactly #{content} and no newline using command.
               Call reply_attachment with path /workspace/handoff.txt, name handoff.txt,
               and mimeType text/plain. Then reply exactly HANDOFF_READY.
               Do not send an attachment before creating the file.
               """
             )

    input = actor_event_by_source_entry_id!(ctx.agent.uid, source_id)
    assert {:ok, _} = ensure_input_driver!(input, input.available_at)

    assert {:ok, true} =
             Ankole.E2E.WaitHelpers.wait_until(deadline(180_000), fn ->
               Repo.get!(Ankole.SignalsGateway.ActorEvent, input.id).completed_at != nil
             end)

    [attachment_outbox] =
      Repo.all(
        from(o in Ankole.SignalsGateway.OutboxEntry,
          where: o.source_actor_event_id == ^input.id
        )
      )
      |> Enum.filter(&match?([_], &1.payload["attachments"]))

    assert attachment_outbox.status == :created
    [attachment] = attachment_outbox.payload["attachments"]
    assert {:ok, _, ^content} = Ankole.Files.read(ctx.agent.uid, attachment["path"])

    assert Ankole.E2E.DockerWorker.exec!(ctx.container, ["cat", "/workspace/handoff.txt"]) ==
             content

    # Exhaust the HTTP client's three retries after platform acceptance, so
    # the durable Outbox must own the later retry of the same intent.
    for _ <- 1..4 do
      :ok =
        FakeFeishu.State.fail_next(ctx.fake_feishu.state, :reply_message, :accepted_then_http_500)
    end

    assert {:ok, failed} =
             Ankole.SignalsGateway.dispatch_outbox_by_key(
               attachment_outbox.agent_uid,
               attachment_outbox.binding_name,
               attachment_outbox.outbound_key
             )

    assert failed.status == :failed
    assert failed.recovery_state == %{}
    assert %DateTime{} = failed.next_attempt_at

    [accepted] =
      FakeFeishu.State.visible_messages(ctx.fake_feishu.state, "oc_real_delivery_loss")
      |> Enum.filter(&(&1.msg_type == "file"))

    file_key = JSON.decode!(accepted.content)["file_key"]

    assert %{content: ^content, name: "handoff.txt"} =
             FakeFeishu.State.uploaded_file(ctx.fake_feishu.state, file_key)

    assert {:ok, sent} =
             Ankole.SignalsGateway.dispatch_outbox_by_key(
               failed.agent_uid,
               failed.binding_name,
               failed.outbound_key,
               now: failed.next_attempt_at
             )

    assert sent.status == :succeeded
    assert sent.created_source_entry_id == accepted.id

    assert FakeFeishu.State.visible_messages(ctx.fake_feishu.state, "oc_real_delivery_loss")
           |> Enum.filter(&(&1.msg_type == "file")) == [accepted]

    assert {:ok, _, ^content} = Ankole.Files.read(ctx.agent.uid, attachment["path"])

    messages = Ankole.E2E.WaitHelpers.ai_messages_for_actor_event(input.id)
    assert command_tool_succeeded?(messages)
    assert tool_result_succeeded?(messages, "reply_attachment")

    assert {:ok, reply, _} =
             wait_for_completed_final_reply(ctx.container, input.id, deadline(60_000))

    assert_lark_final_reply(ctx.fake_feishu, reply, "HANDOFF_READY", :reply, source_id)
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
    assert get_in(completed.metadata, ["codex_user_agent"]) =~ "codex_cli_rs/0.162.1 "

    legacy_auth_path = "/agents/#{ctx.agent.uid}/.codex/auth.json"

    assert Ankole.E2E.DockerWorker.exec!(ctx.container, [
             "sh",
             "-c",
             "test -e #{legacy_auth_path} && echo present || echo absent"
           ]) =~ "absent"
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

    now = DateTime.utc_now(:microsecond)

    if is_nil(event.completed_at) and event.input_state == "open" and
         DateTime.compare(event.available_at, now) != :gt do
      assert {:ok, _result} = ensure_input_driver!(event, now)
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
