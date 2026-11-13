defmodule Ankole.AIGateway.Providers.Jina do
  @moduledoc """
  Jina embedding and rerank provider.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.UniversalAIRequest

  provider :jina do
    label(%{"default" => "Jina Embedding & Rerank", "zh-Hans-CN" => "Jina 嵌入与重排"})
    base_url("https://api.jina.ai/v1", advanced: true)

    setting(:api_key, encrypted: true, scope: :credential)
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)

    setting(:embedding_type, scope: :request, advanced: true)
    setting(:task, scope: :request, advanced: true)
    setting(:dimensions, scope: :request, advanced: true)
    setting(:normalized, scope: :request, advanced: true)
    setting(:late_chunking, scope: :request, advanced: true)
    setting(:truncate, scope: :request, advanced: true)
    setting(:return_multivector, scope: :request, advanced: true)
    setting(:return_documents, scope: :request, advanced: true)
    setting(:top_n, scope: :request, advanced: true)

    embedding_model do
      api_resolver(:jina_embeddings)
      prepare(:prepare_embedding_model)
    end

    rerank_model do
      api_resolver(:jina_rerank)
      prepare(:prepare_rerank_model)
    end
  end

  def prepare_embedding_model(ctx) do
    ctx
    |> UniversalAIRequest.new("embeddings", :jina_embeddings)
    |> UniversalAIRequest.bearer_auth()
  end

  @doc """
  Builds a Jina rerank request.

  Jina rerank has its own request options and response fields, so it uses a
  provider-specific resolver instead of the OpenRouter rerank resolver.
  """
  def prepare_rerank_model(ctx) do
    ctx
    |> UniversalAIRequest.new("rerank", :jina_rerank)
    |> UniversalAIRequest.bearer_auth()
  end
end
