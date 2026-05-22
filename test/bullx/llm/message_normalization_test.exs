defmodule BullX.LLM.MessageNormalizationTest do
  use BullX.DataCase, async: false

  alias BullX.AIAgent.FakeLLMClient
  alias BullX.LLM.{PluginProviders, Writer}
  alias ReqLLM.Message.ContentPart

  setup do
    ReqLLM.Providers.initialize()
    PluginProviders.sync_builtin_extensions()
    allow_catalog_cache()

    previous_llm = Application.get_env(:bullx, :llm, [])

    Application.put_env(
      :bullx,
      :llm,
      Keyword.put(previous_llm, :client, FakeLLMClient)
    )

    FakeLLMClient.reset()

    {:ok, _provider} =
      Writer.put_provider(%{
        provider_id: "openai_proxy",
        req_llm_provider: "openai",
        api_key: "sk-test",
        provider_options: %{"auth_mode" => "api_key"}
      })

    on_exit(fn ->
      Application.put_env(:bullx, :llm, previous_llm)
      FakeLLMClient.reset()
      BullX.LLM.Catalog.Cache.refresh_all()
    end)

    :ok
  end

  test "chat merges user and system text-only content parts before the client call" do
    FakeLLMClient.push_response("ok")

    messages = [
      %ReqLLM.Message{
        role: :system,
        content: [ContentPart.text("system one"), ContentPart.text("system two")]
      },
      %ReqLLM.Message{
        role: :user,
        content: [ContentPart.text("user one"), ContentPart.text("user two")]
      },
      %ReqLLM.Message{
        role: :assistant,
        content: [ContentPart.text("assistant one"), ContentPart.text("assistant two")]
      }
    ]

    assert {:ok, %{text: "ok"}} = BullX.LLM.chat("openai_proxy:gpt-test", messages)

    assert %{
             kind: :chat,
             messages: [
               %ReqLLM.Message{role: :system, content: system_content},
               %ReqLLM.Message{role: :user, content: user_content},
               %ReqLLM.Message{role: :assistant, content: assistant_content}
             ]
           } = FakeLLMClient.last_request()

    assert [%ContentPart{type: :text, text: "system one\nsystem two"}] = system_content
    assert [%ContentPart{type: :text, text: "user one\nuser two"}] = user_content

    assert [
             %ContentPart{type: :text, text: "assistant one"},
             %ContentPart{type: :text, text: "assistant two"}
           ] = assistant_content
  end

  test "stream_chat uses the same user text normalization" do
    FakeLLMClient.push_stream_response(["ok"])

    messages = [
      %ReqLLM.Message{
        role: :user,
        content: [ContentPart.text("line one"), ContentPart.text("line two")]
      }
    ]

    assert {:ok, %{text: "ok"}} = BullX.LLM.stream_chat("openai_proxy:gpt-test", messages, [], [])

    assert %{
             kind: :stream_chat,
             messages: [%ReqLLM.Message{role: :user, content: user_content}]
           } = FakeLLMClient.last_request()

    assert [%ContentPart{type: :text, text: "line one\nline two"}] = user_content
  end

  defp allow_catalog_cache do
    case GenServer.whereis(BullX.LLM.Catalog.Cache) do
      pid when is_pid(pid) -> Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), pid)
      nil -> :ok
    end
  end
end
