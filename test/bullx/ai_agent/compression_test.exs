defmodule BullX.AIAgent.CompressionTest do
  use BullX.DataCase, async: false

  alias BullX.AIAgent.{Compression, Conversation, Conversations, Message, Profile, PromptRenderer}
  alias BullX.LLM.{PluginProviders, Writer}
  alias BullX.Principals

  setup do
    ReqLLM.Providers.initialize()
    PluginProviders.sync_builtin_extensions()
    allow_catalog_cache()
    BullX.LLM.Catalog.Cache.refresh_all()

    previous_llm = Application.get_env(:bullx, :llm, [])

    Application.put_env(
      :bullx,
      :llm,
      Keyword.put(previous_llm, :client, BullX.AIAgent.FakeLLMClient)
    )

    BullX.AIAgent.FakeLLMClient.reset()

    {:ok, _provider} =
      Writer.put_provider(%{
        provider_id: "openai_proxy",
        req_llm_provider: "openai",
        api_key: "sk-test",
        provider_options: %{"auth_mode" => "api_key"}
      })

    on_exit(fn ->
      Application.put_env(:bullx, :llm, previous_llm)
      BullX.AIAgent.FakeLLMClient.reset()
      BullX.LLM.Catalog.Cache.refresh_all()
    end)

    :ok
  end

  test "manual compression writes a summary overlay without rewriting raw messages" do
    {:ok, %{principal: agent}} =
      Principals.create_agent(%{
        uid: "ai-agent-compression",
        display_name: "Agent",
        profile: %{"ai_agent" => %{"main_model" => "openai_proxy:gpt-test"}}
      })

    {:ok, profile} =
      Profile.cast(%{"ai_agent" => %{"main_model" => "openai_proxy:gpt-test"}})

    profile = %{
      profile
      | context:
          Map.merge(profile.context, %{
            context_limit_tokens: 1_000,
            compression_threshold_ratio: 0.10
          })
    }

    {:ok, conversation} = Conversations.find_or_create_active(agent.id, "v1:compress", %{})

    {:ok, conversation, _first} =
      Conversations.append_message(conversation, %{
        conversation_id: conversation.id,
        role: :user,
        kind: :normal,
        status: :complete,
        content: [Message.text_block("first turn raw text")],
        metadata: %{}
      })

    {:ok, conversation, _assistant} =
      Conversations.append_message(conversation, %{
        conversation_id: conversation.id,
        role: :assistant,
        kind: :normal,
        status: :complete,
        content: [Message.text_block("assistant raw text")],
        metadata: %{}
      })

    {:ok, conversation, _second} =
      Conversations.append_message(conversation, %{
        conversation_id: conversation.id,
        role: :user,
        kind: :normal,
        status: :complete,
        content: [Message.text_block("second turn raw text")],
        metadata: %{}
      })

    {:ok, conversation, _second_assistant} =
      Conversations.append_message(conversation, %{
        conversation_id: conversation.id,
        role: :assistant,
        kind: :normal,
        status: :complete,
        content: [Message.text_block("second assistant tail")],
        metadata: %{}
      })

    BullX.AIAgent.FakeLLMClient.push_response("Goal\nPreserve the compressed context.")

    assert {:ok, %{status: :ok, summary_message_id: summary_id}} =
             Compression.manual_compress(conversation, %{profile: profile})

    summary = Repo.get!(Message, summary_id)
    assert summary.kind == :summary
    assert [%{"text" => summary_text}] = summary.content
    assert summary_text =~ "<meta>original_dialogue_time_range:"
    assert summary_text =~ "Preserve the compressed context."

    conversation = Repo.get!(Conversation, conversation.id)

    {:ok, conversation, new_user} =
      Conversations.append_message(conversation, %{
        conversation_id: conversation.id,
        role: :user,
        kind: :normal,
        status: :complete,
        content: [Message.text_block("new tail")],
        metadata: %{}
      })

    assert {:ok, rendered} = PromptRenderer.render(conversation, profile, new_user)

    rendered_text =
      rendered.messages |> Enum.flat_map(&List.wrap(&1.content)) |> Enum.map_join("", & &1.text)

    assert rendered_text =~ "Preserve the compressed context."
    assert rendered_text =~ "new tail"
    assert rendered_text =~ "second turn raw text"
    assert rendered_text =~ "second assistant tail"
    refute rendered_text =~ "first turn raw text"
    refute rendered_text =~ "assistant raw text"

    assert 6 = Repo.aggregate(Message, :count)
  end

  defp allow_catalog_cache do
    case GenServer.whereis(BullX.LLM.Catalog.Cache) do
      pid when is_pid(pid) -> Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), pid)
      nil -> :ok
    end
  end
end
