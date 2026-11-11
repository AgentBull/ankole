defmodule Ankole.AIGateway.Providers.Cloudflare do
  @moduledoc """
  Cloudflare provider: Web Search through AI Gateway, and decision, image,
  speech, and transcription models through Workers AI.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.UniversalAIRequest

  @timeout_ms 120_000

  provider :cloudflare do
    label(%{"default" => "Cloudflare", "zh-Hans-CN" => "Cloudflare"})
    base_url("https://api.cloudflare.com/client/v4", advanced: true)

    setting(:api_key, encrypted: true, scope: :credential)
    setting(:account_id, required: true)
    setting(:gateway_id, default: "default")
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)

    setting(:engine,
      options: ~w(ceramic exa linkup),
      scope: :request,
      capabilities: [:web_search]
    )

    setting(:steps, type: :integer, scope: :request, capabilities: [:image_generate])
    setting(:seed, type: :integer, scope: :request, capabilities: [:image_generate])

    setting(:safety_tolerance,
      type: :integer,
      scope: :request,
      capabilities: [:image_generate]
    )

    web_search do
      api_resolver(:cloudflare_web_search)
      prepare(:prepare_web_search)
      timeout_ms(@timeout_ms)
    end

    decision_model do
      api_resolver(:cloudflare_decision)
      prepare(:prepare_decision_model)
      timeout_ms(@timeout_ms)
    end

    image_generate do
      api_resolver(:cloudflare_images)
      prepare(:prepare_image_generate)
      timeout_ms(300_000)
    end

    speech_model do
      api_resolver(:cloudflare_speech)
      prepare(:prepare_speech_model)
      timeout_ms(300_000)
    end

    transcription_model do
      api_resolver(:cloudflare_transcription)
      prepare(:prepare_transcription_model)
      timeout_ms(300_000)
    end
  end

  @unsupported_image_fields ~w(
    quality background output_compression input_fidelity input_image_mask moderation
  )
  @max_reference_images 8

  @doc """
  Builds a Cloudflare Web Search request. Cloudflare bills the search through
  the account's AI Gateway, so the request names that gateway, and it calls
  the search engine `provider`.
  """
  def prepare_web_search(ctx) do
    provider_options = Map.put(ctx.provider_options, "gateway_id", ctx.settings[:gateway_id])

    ctx
    |> UniversalAIRequest.new(account_path(ctx, "ai/websearch/"), :cloudflare_web_search,
      include_model: false
    )
    |> UniversalAIRequest.bearer_auth()
    |> UniversalAIRequest.put_provider_options(provider_options)
    |> UniversalAIRequest.rename_provider_option("engine", "provider")
  end

  @doc """
  Builds a decision-model request. Workers AI models such as
  `@cf/cloudflare/clef` have their own run path; partner models such as
  `typesafe/jev` share the unified run path.
  """
  def prepare_decision_model(ctx) do
    case ctx.model do
      "@cf/" <> _model ->
        decision_request(ctx, "ai/run/" <> ctx.model)

      _partner_model when is_map_key(ctx.request, "images") ->
        {:error,
         OpenAIError.invalid(
           "images",
           "unsupported_value",
           "The configured decision model does not accept images."
         )}

      _partner_model ->
        decision_request(ctx, "ai/run")
    end
  end

  @doc """
  Builds an image request. FLUX.1 [schnell] on Workers AI has its own run path;
  Black Forest Labs models share the unified run path.
  """
  def prepare_image_generate(ctx) do
    path =
      case ctx.model do
        "@cf/" <> _model -> "ai/run/" <> ctx.model
        _partner_model -> "ai/run"
      end

    ctx
    |> UniversalAIRequest.new(account_path(ctx, path), :cloudflare_images, include_model: false)
    |> UniversalAIRequest.bearer_auth()
  end

  @doc """
  Builds a text-to-speech request for a Deepgram Aura model on Workers AI.
  These models answer with MP3 audio and keep their own speaking rate and
  delivery.
  """
  def prepare_speech_model(ctx) do
    cond do
      ctx.request["response_format"] != "mp3" ->
        unsupported_speech_field("response_format")

      field = Enum.find(~w(speed instructions), &is_map_key(ctx.request, &1)) ->
        unsupported_speech_field(field)

      true ->
        ctx
        |> UniversalAIRequest.new(account_path(ctx, "ai/run/" <> ctx.model), :cloudflare_speech,
          include_model: false
        )
        |> UniversalAIRequest.bearer_auth()
    end
  end

  @doc """
  Builds a speech-to-text request for a Workers AI model that takes base64
  audio, such as `@cf/openai/whisper-large-v3-turbo`.
  """
  def prepare_transcription_model(ctx) do
    ctx
    |> UniversalAIRequest.new(
      account_path(ctx, "ai/run/" <> ctx.model),
      :cloudflare_transcription,
      include_model: false
    )
    |> UniversalAIRequest.bearer_auth()
  end

  defp unsupported_speech_field(field) do
    {:error,
     OpenAIError.invalid(
       field,
       "unsupported_value",
       "The configured speech model does not accept #{field}."
     )}
  end

  @doc """
  Serves FLUX.1 [schnell], which only turns a prompt into an image, and the
  Black Forest Labs models, which also take a size, an output format, and up
  to eight reference images.
  """
  @impl Ankole.AIGateway.Provider
  def image_endpoint("@cf/black-forest-labs/flux-1-schnell", tool, reference_count) do
    cond do
      reference_count > 0 ->
        {:error, {:unsupported_field, "input"}}

      field = present_field(tool, ["size", "output_format" | @unsupported_image_fields]) ->
        {:error, {:unsupported_field, field}}

      true ->
        whole_image_endpoint(tool)
    end
  end

  def image_endpoint("black-forest-labs/" <> _model, tool, reference_count) do
    cond do
      reference_count > @max_reference_images ->
        {:error, {:unsupported_field, "input"}}

      field = present_field(tool, @unsupported_image_fields) ->
        {:error, {:unsupported_field, field}}

      true ->
        whole_image_endpoint(tool)
    end
  end

  def image_endpoint(_model, _tool, _reference_count), do: {:error, :unknown_model}

  # Neither endpoint streams partial images.
  defp whole_image_endpoint(tool) do
    if Map.get(tool, "partial_images", 0) > 0,
      do: {:error, {:unsupported_field, "partial_images"}},
      else: {:ok, %{}}
  end

  # `auto` leaves the choice to the model, so it asks for nothing.
  defp present_field(tool, fields),
    do: Enum.find(fields, &(Map.get(tool, &1) not in [nil, "auto"]))

  defp decision_request(ctx, path) do
    ctx
    |> UniversalAIRequest.new(account_path(ctx, path), :cloudflare_decision, include_model: false)
    |> UniversalAIRequest.bearer_auth()
  end

  defp account_path(ctx, path), do: "accounts/#{ctx.settings[:account_id]}/#{path}"
end
