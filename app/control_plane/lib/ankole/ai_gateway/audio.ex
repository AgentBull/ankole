defmodule Ankole.AIGateway.Audio do
  @moduledoc """
  Speech and transcription requests.

  A speech request turns `input` text into audio through the Pod or Site
  `speech` profile. A transcription request turns `input_audio` into text
  through the `transcription` profile. Neither has a language-model fallback:
  a request whose profile is not configured fails with
  `model_profile_not_configured`.
  """

  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.RequestExecution
  alias Ankole.AIGateway.RequestParams
  alias Ankole.AIGateway.Resolver
  alias Ankole.AIGateway.UsageLedger

  @speech_fields ~w(input voice response_format speed instructions)
  @transcription_fields ~w(input_audio language response_format vad_filter)

  @speech_content_types %{"mp3" => "audio/mpeg", "pcm" => "audio/pcm"}
  @max_audio_bytes 25 * 1024 * 1024
  # Long text becomes more audio than the kernel's default response limit holds.
  @max_speech_bytes 128 * 1024 * 1024
  @audio_format ~r/\A[A-Za-z0-9][A-Za-z0-9+._-]{0,15}\z/

  @doc """
  Returns the generated audio as `%{"audio" => bytes, "content_type" => type}`.
  """
  @spec create_speech(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_speech(subject_uid, request, opts) when is_map(request) do
    with {:ok, request} <- RequestParams.prepare(request, @speech_fields),
         {:ok, request} <- validate_speech(request),
         {:ok, runtime} <- Resolver.resolve_request_model(subject_uid, "speech", request),
         {:ok, prepared_request} <-
           Providers.build_speech_request(runtime, request, max_response_bytes: @max_speech_bytes),
         {:ok, upstream_response} <-
           RequestExecution.execute_prepared_request(runtime, prepared_request, opts),
         {:ok, <<_byte, _rest::binary>> = audio} <-
           Base.decode64(upstream_response.body["audio"] || "") do
      :ok =
        UsageLedger.record_capability(
          runtime,
          Keyword.get(opts, :subject_type),
          upstream_response.body,
          [quantity: String.length(request["input"])] ++ opts
        )

      body = %{
        "audio" => audio,
        "content_type" => speech_content_type(upstream_response.body, request)
      }

      {:ok, RequestExecution.gateway_response(200, body, runtime)}
    else
      {:error, _reason} = error ->
        error

      _no_audio ->
        {:error,
         OpenAIError.server(502, "invalid_speech_output", "The speech model returned no audio.")}
    end
  end

  def create_speech(_subject_uid, _request, _opts), do: {:error, :invalid_request_body}

  # The Provider names the audio that it sent. A Provider that only says
  # "bytes" sent the format that the request asked for.
  defp speech_content_type(%{"content_type" => "audio/" <> _subtype = content_type}, _request),
    do: content_type

  defp speech_content_type(_result, request),
    do: Map.fetch!(@speech_content_types, request["response_format"])

  @doc """
  Returns the transcription: `text` and `usage`, and with
  `response_format: "verbose_json"` also the `language`, `duration`, and
  `segments` that the Provider reports.
  """
  @spec create_transcription(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_transcription(subject_uid, request, opts) when is_map(request) do
    with {:ok, request} <- RequestParams.prepare(request, @transcription_fields),
         :ok <- validate_transcription(request),
         {:ok, runtime} <- Resolver.resolve_request_model(subject_uid, "transcription", request),
         {:ok, prepared_request} <- Providers.build_transcription_request(runtime, request),
         {:ok, upstream_response} <-
           RequestExecution.execute_prepared_request(runtime, prepared_request, opts) do
      result = upstream_response.body
      :ok = UsageLedger.record_capability(runtime, Keyword.get(opts, :subject_type), result, opts)

      fields =
        if request["response_format"] == "verbose_json",
          do: ~w(text language duration segments),
          else: ~w(text)

      body =
        result
        |> Map.take(fields)
        |> Map.put("model", "#{runtime["provider_id"]}/#{runtime["model"]}")
        |> Map.put("usage", Map.take(result["usage"] || %{}, ~w(seconds)))

      {:ok, RequestExecution.gateway_response(200, body, runtime)}
    end
  end

  def create_transcription(_subject_uid, _request, _opts), do: {:error, :invalid_request_body}

  defp validate_speech(request) do
    request = Map.put_new(request, "response_format", "mp3")

    cond do
      not text?(request["input"]) ->
        invalid("input", "missing_required_parameter", "input must be a non-empty string.")

      not optional_text?(request["voice"]) ->
        invalid("voice", "invalid_value", "voice must be a non-empty string.")

      not is_map_key(@speech_content_types, request["response_format"]) ->
        invalid("response_format", "invalid_value", "response_format must be mp3 or pcm.")

      not (is_nil(request["speed"]) or (is_number(request["speed"]) and request["speed"] > 0)) ->
        invalid("speed", "invalid_value", "speed must be a positive number.")

      not optional_text?(request["instructions"]) ->
        invalid("instructions", "invalid_value", "instructions must be a non-empty string.")

      true ->
        {:ok, request}
    end
  end

  defp validate_transcription(request) do
    cond do
      not audio?(request["input_audio"]) ->
        invalid(
          "input_audio",
          "invalid_value",
          "input_audio must be an object with base64 data of up to 25 MiB and a format such as mp3 or wav."
        )

      not optional_text?(request["language"]) ->
        invalid("language", "invalid_value", "language must be a non-empty string.")

      request["response_format"] not in [nil, "json", "verbose_json"] ->
        invalid(
          "response_format",
          "invalid_value",
          "response_format must be json or verbose_json."
        )

      request["vad_filter"] not in [nil, true, false] ->
        invalid("vad_filter", "invalid_value", "vad_filter must be a boolean.")

      true ->
        :ok
    end
  end

  defp audio?(%{"data" => data, "format" => format}) when is_binary(data) and is_binary(format) do
    # Base64 holds three bytes in four characters, so the encoded size settles
    # an oversized upload before it is decoded.
    with true <- Regex.match?(@audio_format, format),
         true <- byte_size(data) <= div(@max_audio_bytes * 4, 3) + 4,
         {:ok, bytes} <- Base.decode64(data) do
      bytes != "" and byte_size(bytes) <= @max_audio_bytes
    else
      _invalid -> false
    end
  end

  defp audio?(_input_audio), do: false

  defp text?(value), do: is_binary(value) and String.trim(value) != ""
  defp optional_text?(value), do: is_nil(value) or text?(value)

  defp invalid(param, code, message), do: {:error, OpenAIError.invalid(param, code, message)}
end
