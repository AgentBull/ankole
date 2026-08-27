defmodule Ankole.Brain.Embeddings do
  @moduledoc """
  Instance-global embedding calls for Brain retrieval projections.

  The model comes from `brain.embedding_model`, and credential resolution
  reuses the configured AIGateway provider row. The embedding signature
  covers only `[provider_kind, model, dimensions]`, so replacing a provider
  row of the same kind does not re-embed the knowledge space. Vectors are
  zero-padded into the fixed `vector(4096)` physical column.
  """

  alias Ankole.AIGateway
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.Brain.Config
  alias Ankole.Kernel, as: NativeKernel

  @subject_uid "brain"
  @physical_dimensions 4096

  @doc "The system Principal that owns instance-global Brain model calls."
  @spec subject_uid() :: String.t()
  def subject_uid, do: @subject_uid

  @doc "The fixed physical vector width."
  @spec physical_dimensions() :: pos_integer()
  def physical_dimensions, do: @physical_dimensions

  @doc """
  Returns the current embedding signature, or an error when no embedding
  model is configured or its provider row is unavailable.
  """
  @spec signature() :: {:ok, String.t()} | {:error, term()}
  def signature do
    with {:ok, model} <- configured_model() do
      signature(model)
    end
  end

  @doc false
  @spec signature(map()) :: {:ok, String.t()} | {:error, term()}
  def signature(%{"provider_id" => provider_id, "model" => model, "dimensions" => dimensions}) do
    with {:ok, provider} <- ProviderConfigs.fetch_active_provider(provider_id) do
      canonical = Enum.join([provider.provider_kind, model, dimensions], "|")
      {:ok, NativeKernel.xxh3_128_hex(canonical)}
    end
  end

  @doc """
  Embeds a list of texts with the instance embedding model.

  Returns vectors zero-padded to the physical width, in input order.
  """
  @spec embed_texts([String.t()]) :: {:ok, [Pgvector.t()]} | {:error, term()}
  def embed_texts([]), do: {:ok, []}

  def embed_texts(texts) when is_list(texts) do
    with {:ok, model} <- configured_model() do
      request =
        %{
          "model" => model["provider_id"] <> "/" <> model["model"],
          "input" => texts,
          "dimensions" => model["dimensions"]
        }
        |> maybe_put_provider_options(model)

      case AIGateway.create_embeddings(@subject_uid, request) do
        {:ok, %{body: body}} -> extract_vectors(body, length(texts), model["dimensions"])
        {:error, _reason} = error -> error
      end
    end
  end

  defp configured_model do
    case Config.embedding_model() do
      nil -> {:error, :embedding_model_not_configured}
      model -> {:ok, model}
    end
  end

  defp maybe_put_provider_options(request, model) do
    case Map.get(model, "provider_options") do
      options when is_map(options) and map_size(options) > 0 ->
        Map.put(request, "provider_options", options)

      _empty ->
        request
    end
  end

  defp extract_vectors(body, expected_count, dimensions) do
    entries = Map.get(body, "data")

    with true <- is_list(entries) and length(entries) == expected_count,
         {:ok, vectors} <- collect_vectors(entries, dimensions) do
      {:ok, vectors}
    else
      false -> {:error, :invalid_embedding_response}
      {:error, _reason} = error -> error
    end
  end

  defp collect_vectors(entries, dimensions) do
    entries
    |> Enum.sort_by(&Map.get(&1, "index", 0))
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case Map.get(entry, "embedding") do
        values when is_list(values) and length(values) == dimensions ->
          {:cont, {:ok, [pad_vector(values) | acc]}}

        values when is_list(values) ->
          {:halt, {:error, {:embedding_dimensions_mismatch, length(values), dimensions}}}

        _invalid ->
          {:halt, {:error, :invalid_embedding_response}}
      end
    end)
    |> case do
      {:ok, vectors} -> {:ok, Enum.reverse(vectors)}
      {:error, _reason} = error -> error
    end
  end

  defp pad_vector(values) do
    padded = values ++ List.duplicate(0.0, @physical_dimensions - length(values))
    Pgvector.new(padded)
  end
end
