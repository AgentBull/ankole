defmodule BullX.Setup.AIAgentsTest do
  use BullX.DataCase, async: false

  alias BullX.LLM.{PluginProviders, Writer}
  alias BullX.Setup.AIAgents

  setup do
    ReqLLM.Providers.initialize()
    PluginProviders.sync_builtin_extensions()
    allow_process(BullX.LLM.Catalog.Cache)

    {:ok, _provider} =
      Writer.put_provider(%{
        provider_id: "openai_proxy",
        req_llm_provider: "openai",
        api_key: "sk-test",
        provider_options: %{"auth_mode" => "api_key"}
      })

    BullX.LLM.Catalog.Cache.refresh_all()

    on_exit(fn -> BullX.LLM.Catalog.Cache.refresh_all() end)

    :ok
  end

  test "save persists setup-visible model and prompt profile fields" do
    assert {:ok, %{agent: agent}} =
             AIAgents.save(%{
               "uid" => "agentbull",
               "display_name" => "AgentBull",
               "main_llm" => %{
                 "provider_id" => "openai_proxy",
                 "model" => "gpt-test",
                 "reasoning_effort" => "high",
                 "context_window" => 40_000
               },
               "compression_llm" => %{
                 "provider_id" => "openai_proxy",
                 "model" => "gpt-4.1-mini",
                 "reasoning_effort" => "low"
               },
               "heavy_llm" => %{
                 "provider_id" => "openai_proxy",
                 "model" => "gpt-4.1",
                 "reasoning_effort" => "xhigh"
               },
               "mission" => "Answer finance questions.",
               "soul" => "Calm and precise.",
               "instructions" => "Do not invent market data."
             })

    profile = agent.profile["ai_agent"]

    assert agent.uid == "agentbull"
    assert profile["main_llm"]["reasoning_effort"] == "high"
    assert profile["main_llm"]["context_window"] == 40_000
    refute Map.has_key?(profile["main_llm"], "max_completion_tokens")
    assert profile["compression_llm"]["provider_id"] == "openai_proxy"
    assert profile["compression_llm"]["model"] == "gpt-4.1-mini"
    assert profile["compression_llm"]["reasoning_effort"] == "low"
    assert profile["heavy_llm"]["model"] == "gpt-4.1"
    assert profile["heavy_llm"]["reasoning_effort"] == "xhigh"
    assert profile["soul"] == "Calm and precise."
    assert profile["instructions"] == "Do not invent market data."
  end

  test "save uses the setup default soul when omitted" do
    assert {:ok, %{agent: agent}} =
             AIAgents.save(%{
               "uid" => "agentbull",
               "display_name" => "AgentBull",
               "main_llm" => %{
                 "provider_id" => "openai_proxy",
                 "model" => "gpt-test",
                 "reasoning_effort" => "medium"
               },
               "mission" => "Answer finance questions."
             })

    assert agent.profile["ai_agent"]["soul"] == AIAgents.default_soul()
  end

  test "save rejects explicit unresolved secondary models" do
    assert {:error, %{message: message}} =
             AIAgents.save(%{
               "uid" => "agentbull",
               "display_name" => "AgentBull",
               "mission" => "Answer finance questions.",
               "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
               "compression_llm" => %{"provider_id" => "missing", "model" => "gpt"}
             })

    assert message =~ "missing"
  end

  test "save rejects missing mission" do
    assert {:error, %{errors: errors}} =
             AIAgents.save(%{
               "uid" => "agentbull",
               "display_name" => "AgentBull",
               "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"}
             })

    assert "mission is required" in errors
  end

  defp allow_process(name) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) -> Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), pid)
      nil -> :ok
    end
  end
end
