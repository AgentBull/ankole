defmodule Ankole.AIGateway.Providers.GoogleVertexAI do
  @moduledoc """
  Google Vertex AI provider, authenticated with service-account keys.

  Vertex AI serves Gemini and its partner models through an OpenAI-compatible
  Chat Completions endpoint that lives under one Google Cloud project and
  location. Each pool credential is a service-account JSON key;
  `ProviderConfigs` exchanges the selected key for an access token before
  this module prepares the request.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.GoogleServiceAccount
  alias Ankole.AIGateway.ReasoningEffort
  alias Ankole.AIGateway.UniversalAIRequest

  @default_base_url "https://aiplatform.googleapis.com/v1"

  @reasoning_effort_map %{
    "low" => "low",
    "medium" => "medium",
    "high" => "high"
  }

  @safety_categories ~w(
    HARM_CATEGORY_HATE_SPEECH
    HARM_CATEGORY_DANGEROUS_CONTENT
    HARM_CATEGORY_SEXUALLY_EXPLICIT
    HARM_CATEGORY_HARASSMENT
  )

  provider "google_vertex_ai" do
    label(%{
      "default" => "Google Vertex AI",
      "zh-Hans-CN" => "Google Vertex AI"
    })

    base_url(@default_base_url, advanced: true)

    setting(:service_account_key, encrypted: true, required: true, scope: :credential)

    setting(:vertex_location, default: "global", advanced: true)
    setting(:project_id, advanced: true)

    setting(:safety_threshold,
      type: :select,
      options: ~w(OFF BLOCK_NONE BLOCK_ONLY_HIGH BLOCK_MEDIUM_AND_ABOVE BLOCK_LOW_AND_ABOVE),
      advanced: true
    )

    setting(:headers, type: :map, advanced: true)

    setting(:reasoningEffort,
      type: :select,
      options: ReasoningEffort.Levels.values(@reasoning_effort_map),
      scope: :request
    )

    language_model do
      api_resolver(:openai_chat_completions)
      prepare(:prepare_language_model)
      supports_parallel_tool_calls()
    end
  end

  @doc "Returns the reasoning-effort target and value map of this provider's language-model requests."
  def reasoning_effort_options, do: [target: :reasoning_effort, map: @reasoning_effort_map]

  @doc """
  Builds a Vertex AI Chat Completions request.

  The endpoint path names the project and location, so the URL is absolute.
  The project comes from the row's `project_id` when the operator set one and
  from the selected service-account key otherwise, which lets one pool hold
  keys of different projects.
  """
  def prepare_language_model(ctx) do
    with {:ok, access_token} <- access_token(ctx.settings),
         {:ok, project_id} <- project_id(ctx.settings) do
      ctx = %{ctx | model: publisher_model(ctx.model)}

      ctx
      |> UniversalAIRequest.new(
        chat_completions_url(ctx.settings, project_id),
        :openai_chat_completions
      )
      |> UniversalAIRequest.put_new_header("x-goog-api-client", "ankole-ai-gateway/0.1")
      |> UniversalAIRequest.bearer_auth(access_token)
      |> ReasoningEffort.put_provider_options(ctx, reasoning_effort_options())
      |> put_safety_settings(ctx.settings[:safety_threshold])
    end
  end

  @doc false
  @impl Ankole.AIGateway.Provider
  def validate_credential_options(options) when is_map(options) do
    case GoogleServiceAccount.parse(Map.get(options, "service_account_key")) do
      {:ok, _key} -> :ok
      {:error, reason} -> {:error, {:credential_options, {:service_account_key, reason}}}
    end
  end

  defp access_token(settings) do
    case settings[:access_token] do
      token when is_binary(token) and token != "" -> {:ok, token}
      _missing -> {:error, :google_vertex_access_token_required}
    end
  end

  defp project_id(settings) do
    case present(settings[:project_id]) do
      nil ->
        with {:ok, key} <- GoogleServiceAccount.parse(settings[:service_account_key]) do
          {:ok, key.project_id}
        end

      project_id ->
        {:ok, project_id}
    end
  end

  # Google publishes regional endpoints on a host named after the location. An
  # operator-supplied base URL (a private endpoint or a proxy) is used as is.
  defp chat_completions_url(settings, project_id) do
    location = present(settings[:vertex_location]) || "global"
    base_url = settings[:base_url] |> to_string() |> String.trim_trailing("/")

    base_url =
      if base_url == @default_base_url and location != "global",
        do: "https://#{location}-aiplatform.googleapis.com/v1",
        else: base_url

    "#{base_url}/projects/#{project_id}/locations/#{location}/endpoints/openapi/chat/completions"
  end

  # The endpoint addresses a model as `publisher/model`. Operators type the
  # name that Google's model pages show, so a bare name is a Google model.
  defp publisher_model(model) when is_binary(model) do
    if model == "" or String.contains?(model, "/"), do: model, else: "google/" <> model
  end

  defp publisher_model(model), do: model

  defp put_safety_settings({:error, _reason} = error, _threshold), do: error

  defp put_safety_settings(%UniversalAIRequest{} = request, threshold) do
    case present(threshold) do
      nil ->
        request

      threshold ->
        safety_settings =
          Enum.map(@safety_categories, &%{"category" => &1, "threshold" => threshold})

        # Vertex AI turns `reasoning_effort` into a top-level `google` member
        # and rejects a request that also carries `extra_body.google`, so the
        # safety settings use the top-level member as well.
        UniversalAIRequest.put_provider_options(
          request,
          Map.put(request.provider_options || %{}, "google", %{
            "safety_settings" => safety_settings
          })
        )
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
