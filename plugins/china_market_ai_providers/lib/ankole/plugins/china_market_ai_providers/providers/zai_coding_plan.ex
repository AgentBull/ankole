defmodule Ankole.Plugins.ChinaMarketAIProviders.Providers.ZaiCodingPlan do
  @moduledoc """
  Z.AI Coding Plan provider backed by the coding OpenAI-compatible endpoint.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.ProviderConnectionCheck
  alias Ankole.AIGateway.UniversalAIRequest

  @timeout_ms 300_000
  @global_base_url "https://api.z.ai/api/coding/paas/v4"
  @china_base_url "https://open.bigmodel.cn/api/coding/paas/v4"
  # Z.AI's coding endpoint has been observed to behave like a desktop-client
  # surface. Keep the compatibility UA configurable so operators can remove or
  # update it without code changes if the upstream requirement changes.
  @default_user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) CherryStudio/1.8.2 Chrome/146.0.7680.188 Electron/41.2.1 Safari/537.36"

  provider "zai_coding_plan" do
    label(%{"default" => "Z.AI Coding Plan", "zh-Hans-CN" => "Z.AI Coding Plan"})
    base_url(@global_base_url)

    setting(:api_key, encrypted: true)
    setting(:china_server, type: :boolean, default: false)
    setting(:user_agent, default: @default_user_agent)
    setting(:headers, type: :map)
    setting(:query_params, type: :map)

    setting(:user, scope: :request)
    setting(:thinking, type: :map, scope: :request)
    setting(:response_format, scope: :request)

    language_model do
      upstream(:sse)
      api_resolver(:openai_chat_completions)
      prepare(:prepare_language_model)
      timeout_ms(@timeout_ms)
    end
  end

  def prepare_language_model(ctx) do
    ctx
    |> put_effective_base_url()
    |> UniversalAIRequest.new("chat/completions", :openai_chat_completions)
    |> put_user_agent(ctx)
    |> UniversalAIRequest.bearer_auth()
  end

  @impl true
  def prepare_connection_check(ctx) when is_map(ctx) do
    ctx = put_effective_base_url(ctx)

    headers =
      ctx
      |> UniversalAIRequest.raw_headers()
      |> put_user_agent(ctx)
      |> UniversalAIRequest.bearer_auth(ctx.settings[:api_key])

    ProviderConnectionCheck.get(ctx, "models", headers: headers)
  end

  defp put_effective_base_url(%{settings: settings} = ctx) when is_map(settings) do
    %{ctx | settings: Map.put(settings, :base_url, effective_base_url(settings))}
  end

  defp effective_base_url(settings) do
    base_url = settings[:base_url] |> to_string() |> String.trim_trailing("/")

    cond do
      custom_base_url?(base_url) ->
        base_url

      china_server?(settings) ->
        @china_base_url

      true ->
        @global_base_url
    end
  end

  defp custom_base_url?(""), do: false
  defp custom_base_url?(@global_base_url), do: false
  defp custom_base_url?(@china_base_url), do: false
  defp custom_base_url?(_base_url), do: true

  defp china_server?(settings) do
    settings[:china_server] in [true, "true"]
  end

  defp put_user_agent(request_or_headers, %{settings: settings}) do
    UniversalAIRequest.put_new_header(request_or_headers, "user-agent", user_agent(settings))
  end

  defp user_agent(settings) when is_map(settings) do
    settings[:user_agent]
    |> to_string()
    |> String.trim()
    |> case do
      "" -> @default_user_agent
      value -> value
    end
  end
end
