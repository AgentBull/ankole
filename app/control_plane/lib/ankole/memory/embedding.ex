defmodule Ankole.Memory.Embedding do
  @moduledoc false

  alias Ankole.AIGateway

  @doc false
  @spec create(String.t(), String.t()) ::
          {:ok, [number()], pos_integer()} | {:error, term()}
  def create(model_agent_uid, text)
      when is_binary(model_agent_uid) and is_binary(text) do
    case AIGateway.create_embeddings(model_agent_uid, %{
           "model" => "embedding.default",
           "input" => text
         }) do
      {:ok, %{body: %{"data" => [%{"embedding" => embedding} | _]}}}
      when is_list(embedding) ->
        {:ok, embedding, length(embedding)}

      {:ok, %{body: %{"embeddings" => [%{"embedding" => embedding} | _]}}}
      when is_list(embedding) ->
        {:ok, embedding, length(embedding)}

      {:ok, body} ->
        {:error, {:invalid_embedding_response, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec to_pgvector([number()]) :: String.t()
  def to_pgvector(vector) when is_list(vector) do
    values =
      Enum.map(vector, fn
        value when is_integer(value) -> Integer.to_string(value)
        value when is_float(value) -> :erlang.float_to_binary(value, [:compact, decimals: 10])
      end)

    "[" <> Enum.join(values, ",") <> "]"
  end
end
