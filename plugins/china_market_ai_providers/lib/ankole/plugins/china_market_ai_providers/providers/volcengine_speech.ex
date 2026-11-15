defmodule Ankole.Plugins.ChinaMarketAIProviders.Providers.VolcengineSpeech do
  @moduledoc """
  Volcengine Doubao Speech V3 provider (`openspeech.bytedance.com`):
  unidirectional HTTP text-to-speech (`/api/v3/tts/unidirectional`) and flash
  speech recognition (`/api/v3/auc/bigmodel/recognize/flash`).
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.UniversalAIRequest

  @timeout_ms 300_000
  @default_tts_resource_id "seed-tts-2.0"
  @default_asr_resource_id "volc.bigasr.auc_turbo"

  provider "volcengine_speech" do
    label(%{"default" => "Volcengine Speech", "zh-Hans-CN" => "火山引擎豆包语音"})
    base_url("https://openspeech.bytedance.com", advanced: true)

    setting(:api_key, encrypted: true, scope: :credential)
    setting(:app_key, encrypted: true, scope: :credential, advanced: true)
    setting(:access_key, encrypted: true, scope: :credential, advanced: true)
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)

    setting(:voice, scope: :request, capabilities: [:speech_model])

    setting(:resource_id,
      scope: :request,
      capabilities: [:speech_model, :transcription_model],
      advanced: true
    )

    setting(:language, scope: :request, capabilities: [:transcription_model], advanced: true)

    speech_model do
      api_resolver(:volcengine_speech)
      prepare(:prepare_speech_model)
      timeout_ms(@timeout_ms)
    end

    transcription_model do
      api_resolver(:volcengine_transcription)
      prepare(:prepare_transcription_model)
      timeout_ms(@timeout_ms)
    end
  end

  @impl Ankole.AIGateway.Provider
  def models_metadata_source(_ctx), do: {:ok, {:static, []}}

  @impl Ankole.AIGateway.Provider
  def validate_credential_options(options) when is_map(options) do
    cond do
      present?(Map.get(options, "api_key")) ->
        :ok

      present?(Map.get(options, "app_key")) and present?(Map.get(options, "access_key")) ->
        :ok

      present?(Map.get(options, "app_key")) ->
        {:error, {:credential_options, {:required, "access_key"}}}

      present?(Map.get(options, "access_key")) ->
        {:error, {:credential_options, {:required, "app_key"}}}

      true ->
        {:error, {:credential_options, {:required, "api_key"}}}
    end
  end

  @doc """
  Builds a Volcengine V3 unidirectional TTS request. Accepts `mp3` (default) or
  `pcm`, speaking `speed` from `0.5` to `2.0`, and requires a `voice` speaker ID
  either on the request or on the model profile.
  """
  def prepare_speech_model(ctx) do
    speed = ctx.request["speed"]

    cond do
      ctx.request["response_format"] not in [nil, "mp3", "pcm"] ->
        unsupported("response_format", "The configured speech model outputs MP3 or PCM audio.")

      is_map_key(ctx.request, "instructions") ->
        unsupported("instructions", "The configured speech model does not accept instructions.")

      is_number(speed) and (speed < 0.5 or speed > 2.0) ->
        unsupported("speed", "The configured speech model accepts speed between 0.5 and 2.0.")

      not present?(ctx.request["voice"]) and not present?(ctx.provider_options["voice"]) ->
        {:error,
         OpenAIError.invalid(
           "voice",
           "missing_required_parameter",
           "The configured speech model needs a voice, such as zh_female_vv_uranus_bigtts."
         )}

      true ->
        resource_id =
          present(ctx.provider_options["resource_id"]) ||
            present(ctx.model) ||
            @default_tts_resource_id

        ctx
        |> UniversalAIRequest.new("api/v3/tts/unidirectional", :volcengine_speech,
          include_model: false
        )
        |> put_speech_auth(ctx)
        |> UniversalAIRequest.put_new_header("x-api-resource-id", resource_id)
        |> UniversalAIRequest.put_new_header("x-api-request-id", Ecto.UUID.generate())
        |> UniversalAIRequest.put_provider_options(
          Map.delete(ctx.provider_options, "resource_id")
        )
    end
  end

  @doc """
  Builds a Volcengine V3 flash speech-recognition request
  (`/api/v3/auc/bigmodel/recognize/flash`).
  """
  def prepare_transcription_model(ctx) do
    resource_id =
      present(ctx.provider_options["resource_id"]) || default_asr_resource_id(ctx.model)

    ctx
    |> UniversalAIRequest.new(
      "api/v3/auc/bigmodel/recognize/flash",
      :volcengine_transcription,
      include_model: false
    )
    |> put_speech_auth(ctx)
    |> UniversalAIRequest.put_new_header("x-api-resource-id", resource_id)
    |> UniversalAIRequest.put_new_header("x-api-request-id", Ecto.UUID.generate())
    |> UniversalAIRequest.put_new_header("x-api-sequence", "-1")
    |> UniversalAIRequest.put_provider_options(Map.delete(ctx.provider_options, "resource_id"))
  end

  # Volcengine Speech V3 supports single-key authentication (`X-Api-Key`) as well
  # as app-scoped credentials (`X-Api-App-Key` + `X-Api-Access-Key`).
  defp put_speech_auth(request, %{settings: settings}) do
    case present(settings[:api_key]) do
      api_key when is_binary(api_key) ->
        UniversalAIRequest.put_header(request, "x-api-key", api_key)

      nil ->
        request
        |> UniversalAIRequest.put_header("x-api-app-key", present(settings[:app_key]))
        |> UniversalAIRequest.put_header("x-api-access-key", present(settings[:access_key]))
    end
  end

  defp default_asr_resource_id(model) when is_binary(model) do
    trimmed = String.trim(model)
    if String.starts_with?(trimmed, "volc."), do: trimmed, else: @default_asr_resource_id
  end

  defp default_asr_resource_id(_model), do: @default_asr_resource_id

  defp present(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp present(_value), do: nil

  defp present?(value), do: present(value) != nil

  defp unsupported(param, message),
    do: {:error, OpenAIError.invalid(param, "unsupported_value", message)}
end
