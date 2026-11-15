defmodule Ankole.Plugins.ChinaMarketAIProviders.Providers.VolcengineVisual do
  @moduledoc """
  Volcengine Visual Intelligence OpenAPI provider (`visual.volcengineapi.com`):
  signs OCR requests with Volcengine Signature Version 4 (`HMAC-SHA256`, service
  `cv`), dispatching images to `OCRNormal` and PDFs (or `ocr-pdf` profiles) to
  `OCRPdf`.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.UniversalAIRequest

  @timeout_ms 300_000
  @ocr_normal_query "?Action=OCRNormal&Version=2020-08-26"
  @ocr_pdf_query "?Action=OCRPdf&Version=2020-08-26"

  provider "volcengine_visual" do
    label(%{"default" => "Volcengine Visual", "zh-Hans-CN" => "火山引擎智能视觉"})
    base_url("https://visual.volcengineapi.com", advanced: true)

    setting(:access_key_id, encrypted: true, scope: :credential, required: true)
    setting(:secret_access_key, encrypted: true, scope: :credential, required: true)
    setting(:session_token, encrypted: true, scope: :credential, advanced: true)
    setting(:region, default: "cn-north-1", advanced: true)
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)

    ocr_model do
      api_resolver(:volcengine_visual_ocr)
      prepare(:prepare_ocr_model)
      timeout_ms(@timeout_ms)
    end
  end

  @impl Ankole.AIGateway.Provider
  def models_metadata_source(_ctx), do: {:ok, {:static, []}}

  @doc """
  Builds a Volcengine Visual OpenAPI OCR request (`OCRNormal` for images, or
  `OCRPdf` when the input is a PDF or the profile selects `ocr-pdf`).
  """
  def prepare_ocr_model(ctx) do
    if is_map_key(ctx.request, "pages") do
      {:error,
       OpenAIError.invalid(
         "pages",
         "unsupported_value",
         "The configured OCR model reads the whole document in one call and takes no pages."
       )}
    else
      query =
        if pdf_document?(ctx.request["document"]) or pdf_model?(ctx.model),
          do: @ocr_pdf_query,
          else: @ocr_normal_query

      ctx
      |> UniversalAIRequest.new(query, :volcengine_visual_ocr, include_model: false)
      |> UniversalAIRequest.volcengine_sigv4("cv")
    end
  end

  defp pdf_document?(document) when is_binary(document),
    do: String.starts_with?(document, "data:application/pdf")

  defp pdf_document?(_document), do: false

  defp pdf_model?(model) when is_binary(model) do
    model
    |> String.trim()
    |> String.downcase()
    |> Kernel.in(["ocr-pdf", "ocr_pdf", "ocrpdf"])
  end

  defp pdf_model?(_model), do: false
end
