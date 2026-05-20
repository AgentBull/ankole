defmodule BullX.LLM.ModelRegistry do
  @moduledoc """
  Local model discovery for saved BullX provider rows.

  The registry is local-first: saved `llm_providers` rows decide which providers
  are selectable. Provider modules may enrich that local fact with dynamic model
  lists, but remote discovery never becomes durable truth by itself.
  """

  alias BullX.LLM.{Catalog, ModelConfig, ModelDescriptor, Provider}

  @spec list_provider_models(String.t()) :: {:ok, [ModelDescriptor.t()]} | {:error, term()}
  def list_provider_models(provider_id) when is_binary(provider_id) do
    with {:ok, provider} <- Catalog.find_provider(provider_id),
         {:ok, resolved_provider} <- Catalog.resolve_provider(provider_id),
         {:ok, req_llm_provider, provider_module} <-
           BullX.LLM.ProviderRegistry.fetch(provider.req_llm_provider) do
      dynamic_provider_models(provider, resolved_provider, req_llm_provider, provider_module)
    end
  end

  @spec public_models(String.t()) :: {:ok, [map()]} | {:error, term()}
  def public_models(provider_id) do
    with {:ok, models} <- list_provider_models(provider_id) do
      {:ok, Enum.map(models, &ModelDescriptor.public/1)}
    end
  end

  @spec public_provider_models() :: map()
  def public_provider_models do
    Catalog.list_providers()
    |> Map.new(fn %Provider{provider_id: provider_id} ->
      models =
        case public_models(provider_id) do
          {:ok, models} -> models
          {:error, _reason} -> []
        end

      {provider_id, models}
    end)
  rescue
    _error -> %{}
  end

  defp dynamic_provider_models(provider, resolved_provider, req_llm_provider, provider_module) do
    if function_exported?(provider_module, :list_models, 1) do
      case provider_module.list_models(
             provider_id: provider.provider_id,
             base_url: resolved_provider.base_url,
             opts: resolved_provider.opts
           ) do
        {:ok, [_ | _] = models} -> {:ok, models}
        _error -> {:ok, static_provider_models(provider, req_llm_provider)}
      end
    else
      {:ok, static_provider_models(provider, req_llm_provider)}
    end
  end

  defp static_provider_models(%Provider{} = provider, req_llm_provider) do
    req_llm_provider
    |> LLMDB.models()
    |> Enum.reject(&retired?/1)
    |> Enum.map(&from_llm_db(provider.provider_id, &1))
    |> Enum.sort_by(&String.downcase(&1.label || &1.model))
  rescue
    ArgumentError -> []
  end

  defp from_llm_db(provider_id, %LLMDB.Model{} = model) do
    %ModelDescriptor{
      provider_id: provider_id,
      model: model.id,
      label: model.name || model.id,
      context_window: model.limits && model.limits[:context],
      max_completion_tokens: model.limits && model.limits[:output],
      reasoning: reasoning(model),
      source: :static
    }
  end

  defp reasoning(%LLMDB.Model{capabilities: %{reasoning: %{enabled: true}}}) do
    %{efforts: ModelConfig.reasoning_efforts()}
  end

  defp reasoning(_model), do: %{efforts: [:none]}

  defp retired?(%LLMDB.Model{retired: true}), do: true
  defp retired?(_model), do: false
end
