defmodule Ankole.Conversations.TitleGeneratorTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ecto.Query

  alias Ankole.AIGateway.{ModelProfiles, ProviderConfigs}
  alias Ankole.{Conversations, Files, Repo}
  alias Ankole.Conversations.{Attachments, Events, Message, TitleGenerator}
  alias Ankole.Signals.Signal

  setup do
    alice = human_fixture(%{display_name: "Alice"}).principal

    assistant =
      agent_fixture(%{
        owner_principal_uid: alice.uid,
        display_name: "Assistant",
        type: :personal_assistant
      }).principal

    colleague =
      agent_fixture(%{
        owner_principal_uid: alice.uid,
        display_name: "Reviewer"
      }).principal

    second_colleague =
      agent_fixture(%{
        owner_principal_uid: alice.uid,
        display_name: "Planner"
      }).principal

    for agent <- [colleague, second_colleague] do
      Ankole.ConversationsFixtures.grant_chat(alice.uid, agent.uid)
    end

    %{
      alice: alice,
      actor: actor_fixture(alice.uid),
      assistant: assistant,
      colleague: colleague,
      second_colleague: second_colleague
    }
  end

  test "creates a room with a 40-character first-line fallback and replaces it via the light model",
       ctx do
    owner = self()

    configure_model(ctx.assistant.uid, fn request ->
      send(owner, {:title_request, request.body})
      {:json, 200, response(%{"title" => "  “小应用开发与部署方案。”  "})}
    end)

    long_prompt =
      "我要开发一个小应用用来汇总每个部门每周的客户回访反馈并自动推送告警提醒到群里，后面还要加权限校验\n第二行详细补充说明"

    id = Ash.UUIDv7.generate()

    assert {:ok, initial} =
             Conversations.create(ctx.actor, %{
               conversation_id: id,
               message_id: Ash.UUIDv7.generate(),
               agent_uid: ctx.assistant.uid,
               text: long_prompt
             })

    assert String.length(initial.conversation.title) == 40
    assert initial.conversation.title == String.slice(long_prompt, 0, 40)
    refute initial.conversation.title =~ "第二行"

    signal = Repo.one!(from s in Signal, where: s.conversation_id == ^id)
    :ok = Events.subscribe(id)
    :ok = Events.subscribe_rooms()

    assert :ok = TitleGenerator.generate(ctx.assistant.uid, signal)

    assert_receive {:title_request, body}
    assert body["text"]["format"]["name"] == "pod_conversation_title"
    # A reasoning light model must have budget left for the title after it reasons.
    assert body["max_output_tokens"] >= 2_000
    prompt_input = body["input"] |> hd() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")
    assert prompt_input =~ "<user_message>\n#{long_prompt}\n</user_message>"

    assert_receive {:conversation_event, ^id, :status}
    assert_receive {:pod_conversations_changed}

    assert {:ok, updated} = Conversations.get(ctx.actor, id)
    assert updated.conversation.title == "小应用开发与部署方案"
    assert updated.conversation.title_customized == false
    assert updated.conversation.metadata["generated_title"] == "小应用开发与部署方案"
    assert Enum.all?(updated.messages, &(&1.kind == :message))
  end

  test "attempts title generation at most once across retries, follow-up messages, and multi-agent rooms",
       ctx do
    owner = self()

    for agent <- [ctx.colleague, ctx.second_colleague] do
      configure_model(agent.uid, fn _request ->
        send(owner, {:title_requested, agent.uid})
        {:json, 200, response(%{"title" => "Restock plan review"})}
      end)
    end

    id = Ash.UUIDv7.generate()

    assert {:ok, _} =
             Conversations.create(ctx.actor, %{
               conversation_id: id,
               message_id: Ash.UUIDv7.generate(),
               agent_uid: ctx.colleague.uid,
               room_mode: :group,
               text: "Help us review the Q4 warehouse restock plan."
             })

    assert {:ok, _} =
             Conversations.manage_participants(ctx.actor, id, %{
               add_uids: [ctx.second_colleague.uid]
             })

    [first_signal] = Repo.all(from s in Signal, where: s.conversation_id == ^id)

    assert :ok = TitleGenerator.generate(ctx.colleague.uid, first_signal)
    assert_receive {:title_requested, _}

    # Re-running on the same Signal or on a second Agent in the room skips the model.
    assert :ok = TitleGenerator.generate(ctx.colleague.uid, first_signal)
    assert :ok = TitleGenerator.generate(ctx.second_colleague.uid, first_signal)

    follow_up_id = Ash.UUIDv7.generate()

    assert {:ok, _} =
             Conversations.post(ctx.actor, id, %{
               message_id: follow_up_id,
               target_agent_uid: ctx.second_colleague.uid,
               text: "Also include cold-chain SKUs."
             })

    follow_up_signal =
      Repo.one!(
        from s in Signal,
          where: s.conversation_id == ^id and s.message_id == ^follow_up_id,
          limit: 1
      )

    assert :ok = TitleGenerator.generate(ctx.second_colleague.uid, follow_up_signal)
    refute_receive {:title_requested, _}, 50
  end

  test "skips colleague DMs and attachment-only blank-text opening messages", ctx do
    owner = self()

    for agent <- [ctx.colleague, ctx.assistant] do
      configure_model(agent.uid, fn _request ->
        send(owner, {:unexpected_title_request, agent.uid})
        {:json, 200, response(%{"title" => "Should not run"})}
      end)
    end

    dm_id = Ash.UUIDv7.generate()

    assert {:ok, _} =
             Conversations.create(ctx.actor, %{
               conversation_id: dm_id,
               message_id: Ash.UUIDv7.generate(),
               agent_uid: ctx.colleague.uid,
               text: "Can you inspect the deployment logs?"
             })

    dm_signal = Repo.one!(from s in Signal, where: s.conversation_id == ^dm_id)
    assert :ok = TitleGenerator.generate(ctx.colleague.uid, dm_signal)

    upload =
      upload!(
        ctx.alice.uid,
        "quarterly-customer-feedback-export-2026-q4-final-v2.csv",
        "id,comment\n1,great\n"
      )

    attachment_room_id = Ash.UUIDv7.generate()

    assert {:ok, attachment_detail} =
             Conversations.create(ctx.actor, %{
               conversation_id: attachment_room_id,
               message_id: Ash.UUIDv7.generate(),
               agent_uid: ctx.assistant.uid,
               text: "",
               attachments: [upload.receipt]
             })

    assert attachment_detail.conversation.title ==
             "quarterly-customer-feedback-export-2026-"

    assert [%Message{text: nil}] = attachment_detail.messages

    attachment_signal =
      Repo.one!(from s in Signal, where: s.conversation_id == ^attachment_room_id)

    assert :ok = TitleGenerator.generate(ctx.assistant.uid, attachment_signal)
    refute_receive {:unexpected_title_request, _}, 50
  end

  test "preserves manual renames made before or during generation and restores generated title on reset",
       ctx do
    owner = self()

    # Case 1: Renamed before generation starts -> skips model call completely.
    pre_renamed_id = Ash.UUIDv7.generate()

    assert {:ok, _} =
             Conversations.create(ctx.actor, %{
               conversation_id: pre_renamed_id,
               message_id: Ash.UUIDv7.generate(),
               agent_uid: ctx.assistant.uid,
               text: "Draft an onboarding checklist for new support engineers"
             })

    assert {:ok, _} =
             Conversations.update_conversation(ctx.actor, pre_renamed_id, %{
               title: "Support Onboarding"
             })

    configure_model(ctx.assistant.uid, fn _request ->
      send(owner, {:model_entered, self()})

      receive do
        :finish_model -> :ok
      after
        5_000 -> flunk("timed out waiting to release title model handler")
      end

      {:json, 200, response(%{"title" => "Support Engineer Checklist"})}
    end)

    pre_signal = Repo.one!(from s in Signal, where: s.conversation_id == ^pre_renamed_id)
    assert :ok = TitleGenerator.generate(ctx.assistant.uid, pre_signal)
    refute_receive {:model_entered, _}, 50

    assert {:ok, detail} = Conversations.get(ctx.actor, pre_renamed_id)
    assert detail.conversation.title == "Support Onboarding"
    assert detail.conversation.title_customized == true

    # Case 2: Renamed while the light model request is in flight -> keeps custom title,
    # and clearing the custom title restores the generated title.
    in_flight_id = Ash.UUIDv7.generate()

    assert {:ok, _} =
             Conversations.create(ctx.actor, %{
               conversation_id: in_flight_id,
               message_id: Ash.UUIDv7.generate(),
               agent_uid: ctx.assistant.uid,
               text: "Help me design a checklist for new support engineers"
             })

    in_flight_signal = Repo.one!(from s in Signal, where: s.conversation_id == ^in_flight_id)

    task =
      Task.async(
        Repo.bind_tenant(fn ->
          TitleGenerator.generate(ctx.assistant.uid, in_flight_signal)
        end)
      )

    assert_receive {:model_entered, handler_pid}, 5_000

    assert {:ok, _} =
             Conversations.update_conversation(ctx.actor, in_flight_id, %{
               title: "Pinned Team Checklist"
             })

    send(handler_pid, :finish_model)
    assert :ok = Task.await(task, 5_000)

    assert {:ok, during_detail} = Conversations.get(ctx.actor, in_flight_id)
    assert during_detail.conversation.title == "Pinned Team Checklist"
    assert during_detail.conversation.title_customized == true
    assert during_detail.conversation.metadata["generated_title"] == "Support Engineer Checklist"

    assert {:ok, reset_detail} =
             Conversations.update_conversation(ctx.actor, in_flight_id, %{title: ""})

    assert reset_detail.conversation.title == "Support Engineer Checklist"
    assert reset_detail.conversation.title_customized == false
  end

  test "normalizes model titles and leaves fallback intact when the model fails", ctx do
    assert TitleGenerator.usable_title("  # **“Build Waitlist App”**  \nExtra line") ==
             "Build Waitlist App"

    assert TitleGenerator.usable_title("「部门周报汇总流程。」") == "部门周报汇总流程"
    assert TitleGenerator.usable_title(String.duplicate("甲", 55)) == String.duplicate("甲", 40)
    assert TitleGenerator.usable_title("   ") == nil
    assert TitleGenerator.usable_title("undefined") == nil
    assert TitleGenerator.usable_title("Untitled") == nil
    assert TitleGenerator.usable_title(nil) == nil

    configure_model(ctx.assistant.uid, fn _request ->
      {:json, 500, %{"error" => %{"message" => "upstream unavailable"}}}
    end)

    id = Ash.UUIDv7.generate()

    assert {:ok, initial} =
             Conversations.create(ctx.actor, %{
               conversation_id: id,
               message_id: Ash.UUIDv7.generate(),
               agent_uid: ctx.assistant.uid,
               text: "Investigate why nightly invoice exports stalled"
             })

    signal = Repo.one!(from s in Signal, where: s.conversation_id == ^id)
    assert :ok = TitleGenerator.generate(ctx.assistant.uid, signal)

    assert {:ok, after_failure} = Conversations.get(ctx.actor, id)
    assert after_failure.conversation.title == initial.conversation.title
  end

  defp configure_model(agent_uid, handler) do
    base_url = Ankole.AIGatewayCase.start_upstream_server(handler)
    provider_id = "title-generator-#{agent_uid}-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{"entries" => [%{"label" => "Test", "api_key" => "sk-test"}]}
             })

    assert {:ok, _} =
             ModelProfiles.put_model_profile(agent_uid, "light", %{
               provider_id: provider_id,
               model: "gpt-5.5"
             })
  end

  defp response(value) do
    %{
      "id" => "resp_conversation_title",
      "object" => "response",
      "status" => "completed",
      "output" => [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => Ankole.JSON.encode!(value)}]
        }
      ],
      "usage" => %{"input_tokens" => 12, "output_tokens" => 8}
    }
  end

  defp upload!(uid, name, bytes) do
    local = Files.temp_path()
    File.write!(local, bytes)
    on_exit(fn -> File.rm(local) end)

    {:ok, upload} =
      Attachments.Native.upload(
        actor_fixture(uid),
        Ecto.UUID.generate(),
        name,
        {:file, local},
        "text/csv"
      )

    upload
  end
end
