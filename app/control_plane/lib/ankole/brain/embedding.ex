defmodule Ankole.Brain.Embedding do
  @moduledoc false

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway
  alias Ankole.Brain.Config

  @float32_max 3.4028234663852886e38

  @spec resolve_model_agent_uid() :: {:ok, String.t()} | {:error, term()}
  def resolve_model_agent_uid do
    with {:ok, %{"enabled" => enabled, "model_agent_uid" => model_uid}}
         when enabled in [nil, true] and is_binary(model_uid) <- Config.dreaming(),
         {:ok, _profile} <- ModelProfiles.resolve_runtime_profile(model_uid, "embedding") do
      {:ok, model_uid}
    else
      {:ok, %{"enabled" => false}} -> {:error, :brain_dreaming_disabled}
      {:ok, _config} -> {:error, :brain_embedding_model_not_configured}
      {:error, reason} -> {:error, {:brain_embedding_model_not_configured, reason}}
    end
  end

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
        validate_vector(embedding)

      {:ok, %{body: %{"embeddings" => [%{"embedding" => embedding} | _]}}}
      when is_list(embedding) ->
        validate_vector(embedding)

      {:ok, body} ->
        {:error, {:invalid_embedding_response, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec rerank(String.t(), String.t(), [String.t()], pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def rerank(model_agent_uid, query, documents, limit)
      when is_binary(model_agent_uid) and is_binary(query) and is_list(documents) and
             is_integer(limit) and limit > 0 do
    case AIGateway.create_rerank(model_agent_uid, %{
           "model" => "rerank.default",
           "query" => query,
           "documents" => documents,
           "top_n" => min(limit, length(documents))
         }) do
      {:ok, %{body: %{"results" => results}}} when is_list(results) ->
        normalize_rerank_results(results)

      {:ok, body} ->
        {:error, {:invalid_rerank_response, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec to_pgvector([number()]) :: String.t()
  def to_pgvector(vector) when is_list(vector) do
    values =
      Enum.map(vector, fn
        value when is_integer(value) -> Integer.to_string(value)
        value when is_float(value) -> :erlang.float_to_binary(value, [:compact])
      end)

    "[" <> Enum.join(values, ",") <> "]"
  end

  defp validate_vector([]), do: {:error, {:invalid_embedding_vector, :empty}}

  defp validate_vector(vector) do
    case Enum.find_index(vector, &(not pgvector_number?(&1))) do
      nil ->
        if Enum.any?(vector, &(&1 != 0)),
          do: {:ok, vector, length(vector)},
          else: {:error, {:invalid_embedding_vector, :zero_norm}}

      index ->
        {:error, {:invalid_embedding_vector, {:invalid_component, index}}}
    end
  end

  defp pgvector_number?(value) when is_integer(value),
    do: value >= -@float32_max and value <= @float32_max

  defp pgvector_number?(value) when is_float(value) do
    value >= -@float32_max and value <= @float32_max and
      :erlang.float_to_binary(value, [:compact]) not in ["nan", "inf", "-inf"]
  end

  defp pgvector_number?(_value), do: false

  defp normalize_rerank_results(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn result, {:ok, acc} ->
      case result do
        %{"index" => index, "relevance_score" => score}
        when is_integer(index) and index >= 0 and is_number(score) ->
          {:cont, {:ok, [%{"index" => index, "score" => score} | acc]}}

        _invalid ->
          {:halt, {:error, {:invalid_rerank_result, result}}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end
end
