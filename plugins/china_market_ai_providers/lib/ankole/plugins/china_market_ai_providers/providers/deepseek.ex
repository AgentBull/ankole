defmodule Ankole.Plugins.ChinaMarketAIProviders.Providers.DeepSeek do
  @moduledoc """
  DeepSeek official platform provider (`https://api.deepseek.com`):
  OpenAI-compatible language models (`/chat/completions`) plus DeepSeek's native
  speech (`/v1/tools/tts`), transcription (`/v1/tools/asr`), and document OCR
  (`/v1/tools/ocr`) endpoints.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.UniversalAIRequest

  @timeout_ms 300_000

  provider "deepseek" do
    label(%{"default" => "DeepSeek", "zh-Hans-CN" => "DeepSeek"})
    base_url("https://api.deepseek.com", advanced: true)

    setting(:api_key, encrypted: true, scope: :credential)
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)

    setting(:user, scope: :request, capabilities: [:language_model], advanced: true)
    setting(:response_format, scope: :request, capabilities: [:language_model], advanced: true)

    setting(:thinking,
      type: :map,
      scope: :request,
      capabilities: [:language_model],
      advanced: true
    )

    setting(:voice, options: ~w(stella tide), scope: :request, capabilities: [:speech_model])

    setting(:filter_markdown,
      type: :boolean,
      scope: :request,
      capabilities: [:speech_model],
      advanced: true
    )

    setting(:purpose,
      type: :select,
      options: ~w(text_recognition rich_layout_recognition),
      scope: :request,
      capabilities: [:ocr_model],
      advanced: true
    )

    language_model do
      api_resolver(:openai_chat_completions)
      prepare(:prepare_language_model)
      supports_parallel_tool_calls()
    end

    speech_model do
      api_resolver(:deepseek_speech)
      prepare(:prepare_speech_model)
      timeout_ms(@timeout_ms)
    end

    transcription_model do
      api_resolver(:deepseek_transcription)
      prepare(:prepare_transcription_model)
      timeout_ms(@timeout_ms)
    end

    ocr_model do
      api_resolver(:deepseek_ocr)
      prepare(:prepare_ocr_model)
      timeout_ms(@timeout_ms)
    end
  end

  def prepare_language_model(ctx) do
    ctx
    |> UniversalAIRequest.new("chat/completions", :openai_chat_completions)
    |> UniversalAIRequest.bearer_auth()
  end

  @doc """
  Builds a DeepSeek `/v1/tools/tts` request. Outputs WAV (default) or PCM audio
  with voices such as `stella` and `tide`.
  """
  def prepare_speech_model(ctx) do
    cond do
      ctx.request["response_format"] not in [nil, "wav", "pcm"] ->
        unsupported("response_format", "The configured speech model outputs WAV or PCM audio.")

      field = Enum.find(~w(speed instructions), &is_map_key(ctx.request, &1)) ->
        unsupported(field, "The configured speech model does not accept #{field}.")

      true ->
        ctx
        |> UniversalAIRequest.new(v1_path(ctx, "tools/tts"), :deepseek_speech,
          include_model: false
        )
        |> UniversalAIRequest.bearer_auth()
        |> UniversalAIRequest.put_provider_options(ctx.provider_options)
    end
  end

  @doc """
  Builds a DeepSeek `/v1/tools/asr` multipart speech-recognition request.
  """
  def prepare_transcription_model(ctx) do
    ctx
    |> UniversalAIRequest.new(v1_path(ctx, "tools/asr"), :deepseek_transcription,
      include_model: false
    )
    |> UniversalAIRequest.bearer_auth()
  end

  @doc """
  Builds a DeepSeek `/v1/tools/ocr` multipart document-recognition request.
  """
  def prepare_ocr_model(ctx) do
    if is_map_key(ctx.request, "pages") do
      unsupported(
        "pages",
        "The configured OCR model reads the whole document and takes no pages."
      )
    else
      ctx
      |> UniversalAIRequest.new(v1_path(ctx, "tools/ocr"), :deepseek_ocr, include_model: false)
      |> UniversalAIRequest.bearer_auth()
      |> UniversalAIRequest.put_provider_options(ctx.provider_options)
    end
  end

  # DeepSeek documents `https://api.deepseek.com` as the base URL for chat while
  # mounting audio and OCR tools under `/v1/tools/*`. Avoid doubling `/v1` when
  # an operator configures `https://api.deepseek.com/v1`.
  defp v1_path(ctx, suffix) do
    base_url = ctx.settings[:base_url] |> to_string() |> String.trim_trailing("/")

    if String.ends_with?(base_url, "/v1"),
      do: suffix,
      else: "v1/" <> suffix
  end

  defp unsupported(param, message),
    do: {:error, OpenAIError.invalid(param, "unsupported_value", message)}
end
