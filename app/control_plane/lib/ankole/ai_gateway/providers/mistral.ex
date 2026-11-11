defmodule Ankole.AIGateway.Providers.Mistral do
  @moduledoc """
  Mistral provider: OCR models such as `mistral-ocr-latest`, which read a PDF
  or an image and return Markdown per page.
  https://docs.mistral.ai/api/endpoint/ocr
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.UniversalAIRequest

  provider :mistral do
    label(%{"default" => "Mistral", "zh-Hans-CN" => "Mistral"})
    base_url("https://api.mistral.ai/v1", advanced: true)

    setting(:api_key, encrypted: true, scope: :credential)
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)

    ocr_model do
      api_resolver(:mistral_ocr)
      prepare(:prepare_ocr_model)
      timeout_ms(300_000)
    end
  end

  # This kind serves OCR only, so it lists no language models. An operator
  # types the OCR model's name into the profile.
  @impl Ankole.AIGateway.Provider
  def models_metadata_source(_ctx), do: {:ok, {:static, []}}

  @doc "Builds a Mistral `/ocr` request."
  def prepare_ocr_model(ctx) do
    ctx
    |> UniversalAIRequest.new("ocr", :mistral_ocr, include_model: false)
    |> UniversalAIRequest.bearer_auth()
  end
end
