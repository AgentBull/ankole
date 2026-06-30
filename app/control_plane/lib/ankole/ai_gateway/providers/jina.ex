defmodule Ankole.AIGateway.Providers.Jina do
  @moduledoc """
  Jina embedding and rerank provider.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.UniversalAIRequest

  provider :jina do
    label(%{"default" => "Jina AI", "zh-Hans-CN" => "Jina AI"})
    base_url("https://api.jina.ai/v1")

    setting(:api_key, encrypted: true)
    setting(:headers, type: :map)
    setting(:query_params, type: :map)

    setting(:embedding_type, scope: :request)
    setting(:task, scope: :request)
    setting(:dimensions, scope: :request)
    setting(:normalized, scope: :request)
    setting(:late_chunking, scope: :request)
    setting(:truncate, scope: :request)
    setting(:return_multivector, scope: :request)
    setting(:return_documents, scope: :request)
    setting(:top_n, scope: :request)

    embedding_model do
      upstream(:json)
      api_resolver(:jina_embeddings)
      prepare(:prepare_embedding_model)
    end

    rerank_model do
      upstream(:json)
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
