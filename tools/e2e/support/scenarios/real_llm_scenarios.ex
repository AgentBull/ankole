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
      wait_for_completed_final_reply: 3,
      ai_messages_for_actor_event: 1
    ]

  alias Ankole.AIAgent.Library.Schemas.AgentSkillOverlay
  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.E2E.FakeFeishu
  alias Ankole.Repo
  alias Ankole.SignalsGateway.SignalEntry

  @base_time ~U[2026-07-02 01:34:05.000000Z]
  @real_vision_model "openai/gpt-4o-mini"
  @real_tool_model "openai/gpt-4o-mini"
  @real_text_only_model "qwen/qwen3-30b-a3b"
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
             wait_for_completed_final_reply(container, input.id, deadline(600_000))

    assert reply.text =~ "ANKOLE_OPENROUTER_BROWSER_OK"
    assert reply.text =~ "model="
    assert reply.text =~ "$"

    messages = ai_messages_for_actor_event(input.id)
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

  def run_real_lark_web_fetch_local_browser_turn(%{
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
               @_user_1 Web fetch local-browser task. Use web_fetch exactly once for https://example.com.

               Do not use browser_navigate, browser_click, browser_extract, browser_run, command, read_file, external APIs, direct fetches, or prior knowledge.
               After the web_fetch tool result is visible, reply with one line in this exact format:
               ANKOLE_WEB_FETCH_LOCAL_BROWSER_OK title=<page title> evidence=<short fetched text proving the page content>
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

    assert reply.text =~ "ANKOLE_WEB_FETCH_LOCAL_BROWSER_OK"
    assert reply.text =~ "Example Domain"

    messages = ai_messages_for_actor_event(input.id)
    assert [fetch_call] = tool_results(messages, "web_fetch")
    assert fetch_call.arguments == %{"urls" => ["https://example.com"]}
    refute tool_result_error?(fetch_call)

    fetch_result = fetch_call.result
    assert %{"raw" => fetch_output} = fetch_result
    assert fetch_output =~ "Source: local_browser"
    assert fetch_output =~ "Example Domain"

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
        container: container
      }) do
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
               1. Use the patch tool in replace mode with old_string exactly "" to create /workspace/temp/ankole-terminal-tools-real/orders.csv with exactly this CSV content:
                  region,owner,items
                  north,Ada,2
                  south,Bo,5
                  north,Cy,4
                  west,Dee,3
               2. Use the patch tool in replace mode with old_string exactly "" to create /workspace/temp/ankole-terminal-tools-real/summarize.js. The script must read orders.csv, compute item totals by region, and write report.md.
               3. Run the script with the command tool from /workspace/temp/ankole-terminal-tools-real.
               4. Use read_file to inspect /workspace/temp/ankole-terminal-tools-real/report.md.
               5. Only after the read_file result proves the report, reply exactly:
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
             wait_for_completed_final_reply(container, input.id, deadline(360_000))

    assert reply.text =~ "ANKOLE_TERMINAL_TOOLS_REAL_OK"
    assert reply.text =~ "north=6"
    assert reply.text =~ "south=5"
    assert reply.text =~ "west=3"
    assert reply.text =~ "total=14"

    messages = ai_messages_for_actor_event(input.id)
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

    assert %SignalEntry{text: text, attachments: [attachment]} =
             Repo.get_by!(SignalEntry,
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
