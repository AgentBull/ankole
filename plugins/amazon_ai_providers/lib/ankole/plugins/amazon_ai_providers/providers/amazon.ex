defmodule Ankole.Plugins.AmazonAIProviders.Providers.Amazon do
  @moduledoc """
  Amazon Web Services provider: Polly turns text into speech, and Textract
  reads the text of an image or a one-page PDF.

  Each service has its own regional endpoint, and every request is signed with
  Signature Version 4 from the access key of the selected pool member.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.UniversalAIRequest

  @endpoint "https://{service}.{region}.amazonaws.com"

  provider "amazon" do
    label(%{"default" => "Amazon Web Services", "zh-Hans-CN" => "Amazon Web Services"})
    base_url(@endpoint, advanced: true)

    setting(:access_key_id, encrypted: true, scope: :credential, required: true)
    setting(:secret_access_key, encrypted: true, scope: :credential, required: true)
    setting(:session_token, encrypted: true, scope: :credential)
    setting(:region, required: true)
    setting(:headers, type: :map, advanced: true)

    # Polly needs a voice for every request. The profile's voice serves a
    # request that names none.
    setting(:voice, scope: :request, capabilities: [:speech_model])

    speech_model do
      api_resolver(:amazon_polly_speech)
      prepare(:prepare_speech_model)
      timeout_ms(300_000)
    end

    ocr_model do
      api_resolver(:amazon_textract_ocr)
      prepare(:prepare_ocr_model)
      timeout_ms(300_000)
    end
  end

  @doc """
  Builds a Polly `SynthesizeSpeech` request. The model is the Polly engine,
  such as `neural`. Polly keeps its own speaking rate and delivery.
  """
  def prepare_speech_model(ctx) do
    cond do
      field = Enum.find(~w(speed instructions), &is_map_key(ctx.request, &1)) ->
        unsupported(field, "The configured speech model does not accept #{field}.")

      ctx.request["voice"] in [nil, ""] and ctx.provider_options["voice"] in [nil, ""] ->
        {:error,
         OpenAIError.invalid(
           "voice",
           "missing_required_parameter",
           "The configured speech model needs a voice, such as Joanna."
         )}

      true ->
        ctx
        |> service_request("polly", "v1/speech", :amazon_polly_speech)
        |> UniversalAIRequest.put_provider_options(ctx.provider_options)
    end
  end

  @doc """
  Builds a Textract `DetectDocumentText` request. Textract reads a JPEG or PNG
  image or a one-page PDF in one synchronous call, so it takes no page
  selection.
  """
  def prepare_ocr_model(ctx) do
    cond do
      String.starts_with?(ctx.request["document"], "data:image/webp") ->
        unsupported("document", "The configured OCR model reads PNG and JPEG images and PDFs.")

      is_map_key(ctx.request, "pages") ->
        unsupported("pages", "The configured OCR model reads a one-page PDF and takes no pages.")

      true ->
        ctx
        |> service_request("textract", "/", :amazon_textract_ocr)
        |> UniversalAIRequest.put_header("content-type", "application/x-amz-json-1.1")
        |> UniversalAIRequest.put_header("x-amz-target", "Textract.DetectDocumentText")
    end
  end

  # The default endpoint names the service and the region. An operator who
  # sets another base URL, such as a VPC endpoint, names the whole host.
  defp service_request(ctx, service, path, api_resolver) do
    base_url =
      ctx.settings[:base_url]
      |> String.replace("{service}", service)
      |> String.replace("{region}", to_string(ctx.settings[:region]))

    %{ctx | settings: Map.put(ctx.settings, :base_url, base_url)}
    |> UniversalAIRequest.new(path, api_resolver, include_model: false)
    |> UniversalAIRequest.aws_sigv4(service)
  end

  defp unsupported(param, message),
    do: {:error, OpenAIError.invalid(param, "unsupported_value", message)}
end
