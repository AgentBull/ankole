defmodule Ankole.Brain.Embedding do
  @moduledoc false

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway
  alias Ankole.Brain.Config
  alias Ankole.Repo

  @float32_max 3.4028234663852886e38
  @storage_dimensions 4_096

  @spec resolve_model() ::
          {:ok, %{agent_uid: String.t(), dimensions: pos_integer()}} | {:error, term()}
  def resolve_model do
    with {:ok,
          %{
            "enabled" => true,
            "model_agent_uid" => model_uid,
            "dimensions" => dimensions
          }}
         when is_binary(model_uid) and is_integer(dimensions) <- Config.embedding(),
         {:ok, _profile} <- ModelProfiles.resolve_runtime_profile(model_uid, "embedding") do
      {:ok, %{agent_uid: model_uid, dimensions: dimensions}}
    else
      {:ok, %{"enabled" => false}} -> {:error, :brain_embedding_disabled}
      {:ok, _incomplete} -> {:error, :brain_embedding_not_configured}
      {:error, reason} -> {:error, {:brain_embedding_model_not_configured, reason}}
    end
  end

  @spec create(String.t(), String.t()) ::
          {:ok, [number()], pos_integer()} | {:error, term()}
  def create(model_agent_uid, text)
      when is_binary(model_agent_uid) and is_binary(text) do
    with {:ok, %{agent_uid: ^model_agent_uid, dimensions: dimensions}} <- resolve_model() do
      case AIGateway.create_embeddings(model_agent_uid, %{
             "model" => "embedding.default",
             "input" => text,
             "dimensions" => dimensions
           }) do
        {:ok, %{body: %{"data" => [%{"embedding" => embedding} | _]}}}
        when is_list(embedding) ->
          validate_vector(embedding, dimensions)

        {:ok, %{body: %{"embeddings" => [%{"embedding" => embedding} | _]}}}
        when is_list(embedding) ->
          validate_vector(embedding, dimensions)

        {:ok, body} ->
          {:error, {:invalid_embedding_response, body}}

        {:error, reason} ->
          {:error, reason}
      end
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

  @doc "Pads one configured embedding for the fixed vector storage envelope."
  @spec storage_vector([number()]) :: Pgvector.t()
  def storage_vector(vector) when is_list(vector) and length(vector) <= @storage_dimensions do
    Pgvector.new(vector ++ List.duplicate(0.0, @storage_dimensions - length(vector)))
  end

  @doc false
  @spec prepare_space(String.t(), pos_integer()) :: :ok
  def prepare_space(model_agent_uid, dimensions)
      when is_binary(model_agent_uid) and is_integer(dimensions) and dimensions > 0 do
    case Repo.transact(fn repo ->
           for table <- ~w(brain_entry_blocks brain_episodes) do
             repo.query!(
               """
               UPDATE #{table}
               SET embedding = NULL,
                   embedding_dimensions = NULL,
                   embedding_model_agent_uid = NULL,
                   embedding_state = 'pending',
                   embedding_error = NULL,
                   updated_at = now()
               WHERE embedding_state <> 'pending'
                 AND (
                   embedding_model_agent_uid IS DISTINCT FROM $1 OR
                   embedding_dimensions IS DISTINCT FROM $2
                 )
               """,
               [model_agent_uid, dimensions]
             )
           end

           {:ok, :ok}
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> raise "failed to prepare embedding space: #{inspect(reason)}"
    end
  end

  defp validate_vector([], _expected_dimensions),
    do: {:error, {:invalid_embedding_vector, :empty}}

  defp validate_vector(vector, expected_dimensions) do
    case {length(vector), Enum.find_index(vector, &(not pgvector_number?(&1)))} do
      {dimensions, _index} when dimensions != expected_dimensions ->
        {:error,
         {:invalid_embedding_vector,
          {:unexpected_dimensions, %{expected: expected_dimensions, actual: dimensions}}}}

      {_dimensions, nil} ->
        if Enum.any?(vector, &(&1 != 0)),
          do: {:ok, vector, length(vector)},
          else: {:error, {:invalid_embedding_vector, :zero_norm}}

      {_dimensions, index} ->
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
