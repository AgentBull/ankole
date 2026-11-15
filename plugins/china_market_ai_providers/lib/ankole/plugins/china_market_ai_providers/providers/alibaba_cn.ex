defmodule Ankole.Plugins.ChinaMarketAIProviders.Providers.AlibabaCN do
  @moduledoc """
  Alibaba Cloud Bailian / DashScope provider for the mainland China endpoint:
  OpenAI-compatible language and vision OCR models on `/compatible-mode/v1`, plus
  DashScope multimodal speech (`qwen3-tts-flash`) and transcription
  (`qwen3-asr-flash`) models on `/api/v1/services/aigc/multimodal-generation/generation`.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.UniversalAIRequest

  @timeout_ms 300_000
  @multimodal_generation_path "api/v1/services/aigc/multimodal-generation/generation"

  provider "alibaba_cn" do
    label(%{"default" => "Alibaba Cloud DashScope CN", "zh-Hans-CN" => "阿里云百炼中国区"})
    base_url("https://dashscope.aliyuncs.com/compatible-mode/v1", advanced: true)

    setting(:api_key, encrypted: true, scope: :credential)
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)

    setting(:user, scope: :request, capabilities: [:language_model], advanced: true)
    setting(:response_format, scope: :request, capabilities: [:language_model], advanced: true)

    setting(:enable_search,
      type: :boolean,
      scope: :request,
      capabilities: [:language_model],
      advanced: true
    )

    setting(:search_options,
      type: :map,
      scope: :request,
      capabilities: [:language_model],
      advanced: true
    )

    setting(:enable_thinking,
      type: :boolean,
      scope: :request,
      capabilities: [:language_model],
      advanced: true
    )

    setting(:thinking_budget,
      type: :integer,
      scope: :request,
      capabilities: [:language_model],
      advanced: true
    )

    setting(:repetition_penalty,
      type: :float,
      scope: :request,
      capabilities: [:language_model],
      advanced: true
    )

    setting(:enable_code_interpreter,
      type: :boolean,
      scope: :request,
      capabilities: [:language_model],
      advanced: true
    )

    setting(:vl_high_resolution_images,
      type: :boolean,
      scope: :request,
      capabilities: [:language_model],
      advanced: true
    )

    setting(:incremental_output,
      type: :boolean,
      scope: :request,
      capabilities: [:language_model],
      advanced: true
    )

    setting(:top_k,
      type: :integer,
      scope: :request,
      capabilities: [:language_model],
      advanced: true
    )

    setting(:voice, scope: :request, capabilities: [:speech_model])
    setting(:language_type, scope: :request, capabilities: [:speech_model], advanced: true)
    setting(:language, scope: :request, capabilities: [:transcription_model], advanced: true)

    language_model do
      api_resolver(:openai_chat_completions)
      prepare(:prepare_language_model)
    end

    speech_model do
      api_resolver(:alibaba_dashscope_speech)
      prepare(:prepare_speech_model)
      timeout_ms(@timeout_ms)
    end

    transcription_model do
      api_resolver(:alibaba_dashscope_transcription)
      prepare(:prepare_transcription_model)
      timeout_ms(@timeout_ms)
    end

    ocr_model do
      api_resolver(:alibaba_dashscope_ocr)
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
  Builds a DashScope multimodal speech synthesis request (`qwen3-tts-flash` or
  `qwen3-tts-instruct-flash`). DashScope returns a signed WAV URL or inline WAV
  audio, and takes style guidance via `instructions` rather than `speed`.
  """
  def prepare_speech_model(ctx) do
    cond do
      ctx.request["response_format"] not in [nil, "wav"] ->
        unsupported("response_format", "The configured speech model outputs WAV audio.")

      is_map_key(ctx.request, "speed") ->
        unsupported("speed", "The configured speech model does not accept speed.")

      true ->
        dashscope_multimodal_request(ctx, :alibaba_dashscope_speech)
    end
  end

  @doc """
  Builds a DashScope multimodal speech recognition request (`qwen3-asr-flash`).
  """
  def prepare_transcription_model(ctx) do
    dashscope_multimodal_request(ctx, :alibaba_dashscope_transcription)
  end

  @doc """
  Builds a DashScope vision OCR request (`qwen-vl-ocr` or `qwen3.5-ocr`) on the
  OpenAI-compatible `chat/completions` endpoint.
  """
  def prepare_ocr_model(ctx) do
    cond do
      String.starts_with?(to_string(ctx.request["document"]), "data:application/pdf") ->
        unsupported("document", "The configured OCR model reads PNG, JPEG, and WebP images.")

      is_map_key(ctx.request, "pages") ->
        unsupported("pages", "The configured OCR model reads a single image and takes no pages.")

      true ->
        ctx
        |> UniversalAIRequest.new("chat/completions", :alibaba_dashscope_ocr,
          include_model: false
        )
        |> UniversalAIRequest.bearer_auth()
    end
  end

  # DashScope's multimodal audio APIs live under `/api/v1/...` on the same host
  # as `/compatible-mode/v1`. Stripping the compatibility suffix preserves custom
  # hosts, regional endpoints, and configured query parameters.
  defp dashscope_multimodal_request(ctx, api_resolver) do
    root_url =
      ctx.settings[:base_url]
      |> to_string()
      |> String.trim_trailing("/")
      |> String.replace_suffix("/compatible-mode/v1", "")

    %{ctx | settings: Map.put(ctx.settings, :base_url, root_url)}
    |> UniversalAIRequest.new(@multimodal_generation_path, api_resolver, include_model: false)
    |> UniversalAIRequest.bearer_auth()
    |> UniversalAIRequest.put_provider_options(ctx.provider_options)
  end

  defp unsupported(param, message),
    do: {:error, OpenAIError.invalid(param, "unsupported_value", message)}
end
