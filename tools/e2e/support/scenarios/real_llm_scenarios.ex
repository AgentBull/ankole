defmodule Ankole.E2E.Scenarios.RealLLM do
  @moduledoc """
  Live OpenRouter scenarios that still enter through fake Feishu WS frames.
  """

  import Ecto.Query
  import ExUnit.Assertions

  import Ankole.E2E.Harness

  import Ankole.E2E.WaitHelpers,
    only: [
      deadline: 1,
      wait_for_completed_actor_event_message: 3,
      wait_for_completed_final_reply: 3,
      ai_messages_for_actor_event: 1
    ]

  alias Ankole.AIAgent.Library.Schemas.AgentSkillOverlay
  alias Ankole.AIGateway.AgentConfig
  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AppConfigure
  alias Ankole.CodexDelegations.Schemas.Delegation, as: CodexDelegation
  alias Ankole.CodexDelegations.Schemas.Event, as: CodexDelegationEvent
  alias Ankole.E2E.FakeFeishu
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Entry

  @base_time ~U[2026-07-02 01:34:05.000000Z]
  @real_coding_model "z-ai/glm-5.2"
  @real_vision_model "google/gemini-3.1-flash-lite"
  @real_tool_model "z-ai/glm-5.2"
  @real_text_only_model "z-ai/glm-5.2"
  @codex_real_llm_inactivity_timeout_ms 300_000
  @vision_expected_answer "false"
  @vision_fixture_path Path.expand("../../fixtures/vision-dog.jpeg", __DIR__)

  def run_real_lark_direct_turn(%{fake_feishu: fake_feishu, agent: agent, container: container}) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_real_1",
               message_id: "om_real_1",
               chat_id: "oc_real_llm",
               text: "@_user_1 Reply exactly ANKOLE_LARK_REAL_OK. Do not call tools.",
               mentions: [mention],
               create_time_ms: DateTime.to_unix(@base_time, :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_real_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, input.id, deadline(120_000))

    assert reply.text =~ "ANKOLE_LARK_REAL_OK"
    assert_actor_event_completed!(input.id)

    %{input: input, reply: reply, message: message}
  end

  def run_real_lark_skill_tool_loop(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_real_skill_1",
               message_id: "om_real_skill_1",
               chat_id: "oc_real_llm",
               text: """
               @_user_1 This is a two-step skill_append test.
               Step 1: If you have not yet received a skill_append tool result in this conversation, call skill_append exactly once with name exactly "nano-pdf" and content exactly "Lark real overlay: ANKOLE_LARK_REAL_SKILL_OK".
               Step 2: After the first successful skill_append tool result is visible, do not call any more tools. Reply exactly ANKOLE_LARK_REAL_SKILL_OK.
               """,
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 2, :second), :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_real_skill_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, input.id, deadline(180_000))

    assert reply.text =~ "ANKOLE_LARK_REAL_SKILL_OK"

    messages = ai_messages_for_actor_event(input.id)
    assert tool_result_succeeded?(messages, "skill_append")

    assert %AgentSkillOverlay{overlay_json: %{"text" => content}} =
             AgentSkillOverlay
             |> where([overlay], overlay.agent_uid == ^agent.uid)
             |> where([overlay], overlay.skill_name == "nano-pdf")
             |> where([overlay], is_nil(overlay.deleted_at))
             |> Repo.one()

    assert content == "Lark real overlay: ANKOLE_LARK_REAL_SKILL_OK"

    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply, message: message}
  end

  def run_real_lark_openrouter_browser_turn(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container,
        provider_id: provider_id
      }) do
    put_real_model_profile!(agent.uid, provider_id, "primary", @real_tool_model, %{})

    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_real_openrouter_browser_1",
               message_id: "om_real_openrouter_browser_1",
               chat_id: "oc_real_llm_browser",
               text: """
               @_user_1 Browser-only task. Start at https://openrouter.ai and use the rendered website only.

               Required path:
               1. Use browser_navigate to open https://openrouter.ai.
               2. Use browser_click to enter the Models area from the visible page navigation.
               3. After entering the Models area, call browser_find at least once with a pricing/model query, then use browser_wait/browser_snapshot/browser_scroll as needed to inspect the rendered model list and pricing text.
               4. Do not use command, read_file, browser_run, browser_extract, external APIs, direct fetches, or prior knowledge.

               Find the most expensive model price on OpenRouter's model catalog that you can reveal and compare through the browser. Do not stop at the first page if browser_find/browser_scroll or visible filters show more relevant price lines. Reply with one line in this exact format:
               ANKOLE_OPENROUTER_BROWSER_OK model=<model name> input=<input price or n/a> output=<output price or other billing unit> evidence=<short browser-visible evidence>
               """,
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 8, :second), :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_real_openrouter_browser_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, message} =
             wait_for_completed_final_reply_with_trace(container, input.id, deadline(600_000))

    messages = ai_messages_for_actor_event(input.id)

    assert_text_contains_with_trace!(
      reply.text,
      "ANKOLE_OPENROUTER_BROWSER_OK",
      input.id,
      messages
    )

    assert_text_contains_with_trace!(reply.text, "model=", input.id, messages)
    assert_text_contains_with_trace!(reply.text, "$", input.id, messages)

    assert tool_result_succeeded?(messages, "browser_navigate")
    assert tool_result_succeeded?(messages, "browser_click")
    assert tool_result_succeeded?(messages, "browser_find")

    tool_names =
      messages
      |> function_call_items()
      |> Enum.map(& &1["name"])

    assert Enum.all?(tool_names, &allowed_openrouter_browser_tool?/1)

    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply, message: message}
  end

  def run_real_lark_web_fetch_turn(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container,
        provider_id: provider_id
      }) do
    put_real_model_profile!(agent.uid, provider_id, "primary", @real_tool_model, %{})

    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_real_web_fetch_local_browser_1",
               message_id: "om_real_web_fetch_local_browser_1",
               chat_id: "oc_real_llm_browser",
               text: """
               @_user_1 Web fetch task. Use web_fetch exactly once for https://example.com.

               Do not use browser_navigate, browser_click, browser_extract, browser_run, command, read_file, external APIs, direct fetches, or prior knowledge.
               After the web_fetch tool result is visible, reply with one line in this exact format:
               ANKOLE_WEB_FETCH_LIVE_OK title=<page title> evidence=<short fetched text proving the page content>
               """,
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 9, :second), :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_real_web_fetch_local_browser_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, input.id, deadline(240_000))

    assert reply.text =~ "ANKOLE_WEB_FETCH_LIVE_OK"
    assert reply.text =~ "Example Domain"

    messages = ai_messages_for_actor_event(input.id)
    assert [fetch_call] = tool_results(messages, "web_fetch")
    assert fetch_call.arguments == %{"urls" => ["https://example.com"]}
    refute tool_result_error?(fetch_call)

    fetch_result = fetch_call.result
    assert %{"raw" => fetch_output} = fetch_result
    assert fetch_output =~ "Example Domain"
    assert fetch_output =~ "documentation examples"

    called_tools =
      messages
      |> function_call_items()
      |> Enum.map(& &1["name"])

    assert called_tools == ["web_fetch"]

    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply, message: message}
  end

  def run_real_lark_terminal_tools_turn(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container,
        provider_id: provider_id
      }) do
    put_real_model_profile!(agent.uid, provider_id, "primary", @real_tool_model, %{})

    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_real_terminal_tools_1",
               message_id: "om_real_terminal_tools_1",
               chat_id: "oc_real_llm_terminal_tools",
               text: """
               @_user_1 Terminal tools task in the isolated Ankole Agent Computer workspace. Do not use browser tools, external APIs, or prior knowledge.

               User story: I need a small reproducible pickup report for today's operations handoff.

               Required path:
               1. Use the command tool to create the directory /workspace/temp/ankole-terminal-tools-real.
               2. Use the patch tool in replace mode with old_string exactly "" to create /workspace/temp/ankole-terminal-tools-real/orders.csv with exactly this CSV content:
                  region,owner,items
                  north,Ada,2
                  south,Bo,5
                  north,Cy,4
                  west,Dee,3
               3. Use the patch tool in replace mode with old_string exactly "" to create /workspace/temp/ankole-terminal-tools-real/summarize.js. The script must read orders.csv, compute item totals by region, and write report.md.
               4. Run the script with the command tool from /workspace/temp/ankole-terminal-tools-real.
               5. Use read_file to inspect /workspace/temp/ankole-terminal-tools-real/report.md.
               6. Only after the read_file result proves the report, reply exactly:
                  ANKOLE_TERMINAL_TOOLS_REAL_OK north=6 south=5 west=3 total=14

               The report.md content must include these exact lines:
               north: 6
               south: 5
               west: 3
               total: 14
               """,
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 10, :second), :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_real_terminal_tools_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, message} =
             wait_for_completed_final_reply_with_trace(container, input.id, deadline(360_000))

    messages = ai_messages_for_actor_event(input.id)

    assert_text_contains_with_trace!(
      reply.text,
      "ANKOLE_TERMINAL_TOOLS_REAL_OK",
      input.id,
      messages
    )

    assert_text_contains_with_trace!(reply.text, "north=6", input.id, messages)
    assert_text_contains_with_trace!(reply.text, "south=5", input.id, messages)
    assert_text_contains_with_trace!(reply.text, "west=3", input.id, messages)
    assert_text_contains_with_trace!(reply.text, "total=14", input.id, messages)

    assert replace_create_patch_calls(messages) >= 2
    assert command_tool_succeeded?(messages)

    read_results = successful_tool_results(messages, "read_file")
    assert read_results != []
    final_report = read_results |> List.last() |> inspect()
    assert final_report =~ "north: 6"
    assert final_report =~ "south: 5"
    assert final_report =~ "west: 3"
    assert final_report =~ "total: 14"

    called_tools =
      messages
      |> function_call_items()
      |> Enum.map(& &1["name"])

    refute Enum.any?(called_tools, &String.starts_with?(&1, "browser_"))

    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply, message: message}
  end

  def run_real_lark_codex_todolist_turn(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container,
        provider_id: provider_id
      }) do
    put_real_model_profile!(agent.uid, provider_id, "primary", @real_coding_model, %{})
    put_real_model_profile!(agent.uid, provider_id, "heavy", @real_coding_model, %{})
    put_real_model_profile!(agent.uid, provider_id, "coding", @real_coding_model, %{})
    put_agent_inactivity_timeout!(agent.uid, @codex_real_llm_inactivity_timeout_ms)

    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_real_codex_todolist_1",
               message_id: "om_real_codex_todolist_1",
               chat_id: "oc_real_llm_codex_todolist",
               text: """
               @_user_1 Please delegate this implementation to a Codex subagent, then reply from the delegation result. Use the real OpenRouter model z-ai/glm-5.2.

               Task:
               1. Call codex_delegate exactly once with action="run" and workdir="/workspace/temp/ankole-codex-todolist-real".
               2. The delegated Codex prompt must ask Codex to create the smallest possible Vite + React TypeScript in-memory todolist demo in that workdir. Keep the source tiny and write only package.json plus index.html, src/App.tsx, and src/index.scss.
               3. The app only needs React useState, add/toggle/delete todo behavior, and a visible remaining count. No polish, no extra files, no tests.
               4. The delegated Codex prompt must require Codex to run bun install and bun run build, and its final answer must include ANKOLE_CODEX_TODOLIST_DELEGATE_DONE.
               5. After codex_delegate returns, do not use command or read_file for parent-side verification. If the delegation result contains ANKOLE_CODEX_TODOLIST_DELEGATE_DONE, reply exactly:
                  ANKOLE_CODEX_TODOLIST_REAL_OK build=passed verified=delegation

               This is a delegation run-through task; no web research is needed.
               """,
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 12, :second), :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_real_codex_todolist_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, message} =
             wait_for_completed_actor_event_message(container, input.id, deadline(1_500_000))

    messages = ai_messages_for_actor_event(input.id)

    reply =
      case wait_for_completed_final_reply(container, input.id, deadline(60_000)) do
        {:ok, %Entry{} = reply, %{id: message_id}} when message_id == message.id ->
          reply

        {:ok, %Entry{} = _reply, other_message} ->
          flunk("""
          real Codex todolist turn mirrored a different final message.
          expected_message_id=#{message.id}
          actual_message_id=#{other_message.id}
          final_message_text=#{inspect(message_text(message), printable_limit: 4_000)}
          tool_results=#{inspect(tool_results(messages), limit: :infinity, printable_limit: 4_000)}
          codex_delegations=#{inspect(codex_delegation_debug(input.id), limit: :infinity, printable_limit: 4_000)}
          """)
      end

    delegation =
      Repo.one!(
        from delegation in CodexDelegation,
          where: delegation.agent_uid == ^agent.uid,
          where: delegation.actor_event_id == ^input.id
      )

    assert reply.text =~ "ANKOLE_CODEX_TODOLIST_REAL_OK",
           """
           real Codex todolist turn did not emit the success marker.
           reply_text=#{inspect(reply.text, printable_limit: 8_000)}
           codex_delegations=#{inspect(codex_delegation_debug(input.id), limit: :infinity, printable_limit: 8_000)}
           tool_results=#{inspect(tool_results(messages), limit: :infinity, printable_limit: 8_000)}
           final_message_text=#{inspect(message_text(message), printable_limit: 4_000)}
           """

    assert reply.text =~ "build=passed"
    assert reply.text =~ "verified=delegation"

    assert tool_result_succeeded?(messages, "codex_delegate")

    called_tools =
      messages
      |> function_call_items()
      |> Enum.map(& &1["name"])

    assert "codex_delegate" in called_tools

    assert delegation.status == "succeeded",
           """
           real Codex todolist delegation did not succeed.
           codex_delegations=#{inspect(codex_delegation_debug(input.id), limit: :infinity, printable_limit: 8_000)}
           tool_results=#{inspect(tool_results(messages), limit: :infinity, printable_limit: 8_000)}
           final_message_text=#{inspect(message_text(message), printable_limit: 4_000)}
           """

    assert get_in(delegation.result, ["output_text"]) =~ "ANKOLE_CODEX_TODOLIST_DELEGATE_DONE",
           """
           real Codex todolist delegation succeeded without the expected marker.
           codex_delegations=#{inspect(codex_delegation_debug(input.id), limit: :infinity, printable_limit: 8_000)}
           """

    events =
      Repo.all(
        from event in CodexDelegationEvent,
          where: event.delegation_id == ^delegation.id,
          order_by: [asc: event.seq]
      )

    assert length(events) >= 8
    event_types = Enum.map(events, & &1.event_type)
    assert "config_materialized" in event_types
    assert "json_rpc" in event_types
    assert "status_succeeded" in event_types

    assert Enum.any?(events, fn event ->
             event.event_type == "json_rpc" and
               get_in(event.payload, ["message", "method"]) in [
                 "initialize",
                 "thread/start",
                 "turn/start"
               ]
           end)

    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply, message: message, delegation: delegation}
  end

  def run_real_lark_post_image_direct_vision_turn(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container,
        provider_id: provider_id
      }) do
    put_real_model_profile!(agent.uid, provider_id, "primary", @real_vision_model, %{})

    run_post_image_code_turn(
      fake_feishu,
      agent,
      container,
      event_id: "evt_real_image_direct_1",
      message_id: "om_real_image_direct_1",
      chat_id: "oc_real_llm_image_direct",
      file_key: "img_real_image_direct_1",
      create_time: DateTime.add(@base_time, 4, :second),
      prompt:
        "@_user_1 If the animal in the attached image is herbivorous, reply exactly true. Otherwise reply exactly false. Do not call tools."
    )
  end

  def run_real_lark_post_image_vision_fallback_turn(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container,
        provider_id: provider_id
      }) do
    put_real_model_profile!(agent.uid, provider_id, "primary", @real_text_only_model, %{})
    put_real_model_profile!(agent.uid, provider_id, "vision_fallback", @real_vision_model, %{})

    result =
      run_post_image_code_turn(
        fake_feishu,
        agent,
        container,
        event_id: "evt_real_image_fallback_1",
        message_id: "om_real_image_fallback_1",
        chat_id: "oc_real_llm_image_fallback",
        file_key: "img_real_image_fallback_1",
        create_time: DateTime.add(@base_time, 6, :second),
        prompt:
          "@_user_1 If an <image_summary> block describes the attached image, decide whether the animal is herbivorous. Reply exactly true or false. If no animal is described, reply exactly UNKNOWN. Do not call tools."
      )

    assert_false_answer_text!(result.reply.text)
    assert fallback_summary_recorded?(result.input.id)

    result
  end

  defp run_post_image_code_turn(fake_feishu, agent, container, opts) do
    mention = lark_bot_mention()
    event_id = Keyword.fetch!(opts, :event_id)
    message_id = Keyword.fetch!(opts, :message_id)
    chat_id = Keyword.fetch!(opts, :chat_id)
    file_key = Keyword.fetch!(opts, :file_key)
    create_time = Keyword.fetch!(opts, :create_time)
    prompt = Keyword.fetch!(opts, :prompt)

    assert :ok =
             FakeFeishu.State.put_inbound_file(
               fake_feishu.state,
               file_key,
               vision_image_jpeg(),
               "vision-dog.jpeg"
             )

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: event_id,
               message_id: message_id,
               chat_id: chat_id,
               message_type: "post",
               content: %{
                 "content" => [
                   [
                     %{"tag" => "text", "text" => prompt <> "\n"},
                     %{"tag" => "img", "image_key" => file_key}
                   ]
                 ]
               },
               mentions: [mention],
               create_time_ms: DateTime.to_unix(create_time, :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, message_id)
    assert input.type == "im.message.addressed"

    assert %Entry{text: text, attachments: [attachment]} =
             Repo.get_by!(Entry,
               signal_channel_id: "lark:#{chat_id}",
               source_entry_id: message_id
             )

    assert text =~ "attached image"
    assert text =~ "[image]"

    assert %{
             "provider_ref" => "lark:image:" <> ^file_key,
             "provider" => "lark",
             "source_message_id" => ^message_id,
             "file_key" => ^file_key,
             "download_type" => "image",
             "resource_type" => "image"
           } =
             Map.take(
               attachment,
               ~w(provider_ref provider source_message_id file_key download_type resource_type)
             )

    assert is_binary(attachment["agent_computer_path"])

    assert String.ends_with?(
             attachment["user_files_relative_path"],
             "/#{file_key}/vision-dog.jpeg"
           )

    assert get_in(input.payload, ["data", "entry", "attachments"]) == [attachment]

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, input.id, deadline(180_000))

    assert_false_answer_text!(reply.text)
    assert_actor_event_completed!(input.id)

    %{input: input, reply: reply, message: message}
  end

  defp put_real_model_profile!(agent_uid, provider_id, profile, model, provider_options) do
    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent_uid, profile, %{
               provider_id: provider_id,
               model: model,
               provider_options: provider_options
             })
  end

  defp put_agent_inactivity_timeout!(agent_uid, timeout_ms) do
    assert {:ok, ^timeout_ms} =
             AppConfigure.put_for_agent(
               agent_uid,
               AgentConfig.inactivity_timeout_ms_definition(),
               timeout_ms
             )
  end

  defp codex_delegation_debug(actor_event_id) do
    CodexDelegation
    |> where([delegation], delegation.actor_event_id == ^actor_event_id)
    |> Repo.all()
    |> Enum.map(fn delegation ->
      events =
        CodexDelegationEvent
        |> where([event], event.delegation_id == ^delegation.id)
        |> order_by([event], asc: event.seq)
        |> limit(40)
        |> Repo.all()
        |> Enum.map(&codex_event_debug/1)

      %{
        id: delegation.id,
        status: delegation.status,
        codex_thread_id: delegation.codex_thread_id,
        result: delegation.result,
        error: delegation.error,
        metadata: delegation.metadata,
        events: events
      }
    end)
  end

  defp codex_event_debug(%CodexDelegationEvent{} = event) do
    message = event.payload["message"] || %{}
    params = message["params"] || %{}
    turn = params["turn"] || %{}

    %{
      seq: event.seq,
      direction: event.direction,
      event_type: event.event_type,
      method: message["method"],
      has_result: Map.has_key?(message, "result"),
      rpc_error: message["error"],
      turn_status: turn["status"],
      payload: codex_debug_payload(event.payload)
    }
  end

  defp codex_debug_payload(payload) when is_map(payload) do
    payload
    |> Map.take(~w(error message mode codex_turn_status output_text text max_running_per_agent))
    |> truncate_debug_strings()
  end

  defp truncate_debug_strings(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, truncate_debug_strings(nested)} end)
  end

  defp truncate_debug_strings(value) when is_list(value),
    do: Enum.map(value, &truncate_debug_strings/1)

  defp truncate_debug_strings(value) when is_binary(value) do
    if String.length(value) > 1_000 do
      String.slice(value, 0, 1_000) <> "...[truncated]"
    else
      value
    end
  end

  defp truncate_debug_strings(value), do: value

  defp fallback_summary_recorded?(actor_event_id) do
    actor_event_id
    |> ai_messages_for_actor_event()
    |> Enum.any?(fn message ->
      message
      |> Map.get(:content, [])
      |> Enum.any?(
        &(request_item_text(&1) =~ "<image_summary>" and
            image_summary_text?(request_item_text(&1)))
      )
    end)
  end

  defp request_item_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{"type" => "input_text", "text" => text} when is_binary(text) -> text
      _part -> ""
    end)
    |> Enum.join("\n")
  end

  defp request_item_text(%{"content" => text}) when is_binary(text), do: text
  defp request_item_text(_item), do: ""

  defp assert_false_answer_text!(text) do
    normalized = text |> to_string() |> String.downcase()

    assert String.contains?(normalized, @vision_expected_answer),
           "expected vision answer to say false, got: #{inspect(text)}"

    refute Regex.match?(~r/\btrue\b/, normalized),
           "expected vision answer not to say true, got: #{inspect(text)}"
  end

  defp image_summary_text?(text) when is_binary(text) do
    normalized = String.downcase(text)

    String.contains?(normalized, "dog") or String.contains?(normalized, "labrador") or
      String.contains?(normalized, "canine")
  end

  defp image_summary_text?(_text), do: false

  defp vision_image_jpeg, do: File.read!(@vision_fixture_path)

  defp wait_for_completed_final_reply_with_trace(container, actor_event_id, deadline) do
    wait_for_completed_final_reply(container, actor_event_id, deadline)
  rescue
    error ->
      messages = ai_messages_for_actor_event(actor_event_id)

      raise """
      #{Exception.message(error)}

      actor_event_id=#{actor_event_id}
      ai_message_trace=#{inspect(ai_message_trace(messages), limit: :infinity, printable_limit: 4000)}
      """
  end

  defp ai_message_trace(messages) do
    Enum.map(messages, fn message ->
      %{
        id: message.id,
        status: message.status,
        type: message.type,
        tool_calls: function_call_items([message]) |> Enum.map(&function_call_trace/1),
        text: message_text_excerpt(message.content || [])
      }
    end)
  end

  defp function_call_trace(call) do
    %{
      name: call["name"],
      call_id: call["call_id"],
      arguments: call["arguments"] |> inspect(printable_limit: 1000) |> String.slice(0, 1000)
    }
  end

  defp message_text_excerpt(items) when is_list(items) do
    items
    |> Enum.flat_map(&content_texts/1)
    |> Enum.join("\n")
    |> String.slice(0, 1200)
  end

  defp message_text_excerpt(_items), do: ""

  defp content_texts(%{"text" => text}) when is_binary(text), do: [text]

  defp content_texts(%{"content" => nested}) when is_list(nested),
    do: Enum.flat_map(nested, &content_texts/1)

  defp content_texts(%{"output" => output}) when is_binary(output), do: [output]
  defp content_texts(_item), do: []

  defp assert_text_contains_with_trace!(text, needle, actor_event_id, messages) do
    assert text =~ needle,
           """
           expected reply to contain #{inspect(needle)}, got #{inspect(text)}

           actor_event_id=#{actor_event_id}
           ai_message_trace=#{inspect(ai_message_trace(messages), limit: :infinity, printable_limit: 4000)}
           """
  end

  defp allowed_openrouter_browser_tool?(tool_name) do
    tool_name in [
      "browser_navigate",
      "browser_snapshot",
      "browser_find",
      "browser_click",
      "browser_type",
      "browser_press",
      "browser_scroll",
      "browser_select",
      "browser_wait",
      "browser_back",
      "browser_screenshot"
    ]
  end

  defp replace_create_patch_calls(messages) do
    messages
    |> tool_results("patch")
    |> Enum.count(fn
      %{arguments: %{"old_string" => "", "new_string" => new_string}}
      when is_binary(new_string) ->
        true

      _other ->
        false
    end)
  end
end
