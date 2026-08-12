defmodule Ankole.AIGateway.OpenAIRequestOptionsTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.OpenAIRequestOptions
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.Providers.AzureOpenAI
  alias Ankole.AIGateway.Providers.ChatGPTSubscription
  alias Ankole.AIGateway.Providers.OpenAI
  alias Ankole.AIGateway.Providers.OpenAICompatible
  alias Ankole.AIGateway.UniversalAIRequest

  test "provider definitions expose only accepted OpenAI output choices" do
    assert setting(OpenAI, :reasoningSummary) ==
             {:select, ~w(auto concise detailed), true}

    assert setting(AzureOpenAI, :reasoningSummary) ==
             {:select, ~w(auto concise detailed), true}

    assert setting(OpenAI, :textVerbosity) == {:select, ~w(low medium high), false}
    assert setting(AzureOpenAI, :textVerbosity) == {:select, ~w(low medium high), false}

    for provider <- [ChatGPTSubscription, AzureOpenAI, OpenAI, OpenAICompatible] do
      assert setting(provider, :serviceTier) == {nil, ~w(fast flex), true}
    end

    for provider_kind <- ~w(chatgpt_subscription azure_openai openai openai_compatible) do
      assert :ok =
               Providers.validate_runtime_provider_options(provider_kind, %{
                 "serviceTier" => "fast"
               })

      assert :ok =
               Providers.validate_runtime_provider_options(provider_kind, %{
                 "serviceTier" => "provider-native-tier"
               })
    end

    assert :ok =
             Providers.validate_runtime_provider_options("openai", %{
               "reasoningSummary" => "auto",
               "textVerbosity" => "high"
             })

    assert {:error,
            {:provider_options,
             {:invalid_value, "textVerbosity", "verbose", ["low", "medium", "high"]}}} =
             Providers.validate_runtime_provider_options("openai", %{
               "textVerbosity" => "verbose"
             })
  end

  test "maps Responses output controls into nested native objects" do
    request =
      request(%{
        "reasoning" => %{"effort" => "high"},
        "reasoningSummary" => "detailed",
        "serviceTier" => "fast",
        "textVerbosity" => "low"
      })

    assert %UniversalAIRequest{provider_options: options} =
             OpenAIRequestOptions.put_provider_options(request, :responses)

    assert options == %{
             "reasoning" => %{"effort" => "high", "summary" => "detailed"},
             "service_tier" => "fast",
             "text" => %{"verbosity" => "low"}
           }
  end

  test "maps Chat Completions verbosity and rejects a Responses-only summary" do
    assert %UniversalAIRequest{provider_options: options} =
             request(%{
               "reasoning_effort" => "high",
               "serviceTier" => "flex",
               "textVerbosity" => "medium"
             })
             |> OpenAIRequestOptions.put_provider_options(:chat_completions)

    assert options == %{
             "reasoning_effort" => "high",
             "service_tier" => "flex",
             "verbosity" => "medium"
           }

    assert {:error, {:unsupported_provider_option, "reasoningSummary", "chat_completions"}} =
             request(%{"reasoningSummary" => "auto"})
             |> OpenAIRequestOptions.put_provider_options(:chat_completions)
  end

  defp request(provider_options) do
    %UniversalAIRequest{
      ctx: %{},
      path: "responses",
      api_resolver: :openai_responses,
      provider_options: provider_options
    }
  end

  defp setting(module, key) do
    setting = Enum.find(module.provider_definition().settings, &(&1.key == key))
    {setting.type, setting.options, setting.advanced?}
  end
end
