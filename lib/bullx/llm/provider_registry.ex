defmodule BullX.LLM.ProviderRegistry do
  @moduledoc """
  Resolves BullX provider adapter ids to allowed ReqLLM provider modules.

  ReqLLM may know more adapters than BullX wants to expose. This registry only
  accepts modules declared through BullX plugin metadata or the in-tree BullX
  provider namespace, keeping setup choices aligned with auditable plugins.
  """

  @spec fetch(String.t()) ::
          {:ok, atom(), module()} | {:error, {:unknown_req_llm_provider, String.t()}}
  def fetch(provider_id) when is_binary(provider_id) do
    case find_provider_atom(provider_id) do
      {:ok, provider_atom, module} ->
        case ReqLLM.provider(provider_atom) do
          {:ok, ^module} -> {:ok, provider_atom, module}
          {:ok, _other_module} -> {:error, {:unknown_req_llm_provider, provider_id}}
          {:error, _reason} -> {:error, {:unknown_req_llm_provider, provider_id}}
        end

      :error ->
        {:error, {:unknown_req_llm_provider, provider_id}}
    end
  end

  @spec known?(String.t()) :: boolean()
  def known?(provider_id) when is_binary(provider_id) do
    match?({:ok, _provider_atom, _module}, find_provider_atom(provider_id))
  end

  def known?(_provider_id), do: false

  defp find_provider_atom(provider_id) do
    ReqLLM.Providers.list()
    |> Enum.find(&(Atom.to_string(&1) == provider_id))
    |> case do
      nil -> :error
      provider_atom -> validate_allowed_provider(provider_id, provider_atom)
    end
  end

  defp validate_allowed_provider(provider_id, provider_atom) do
    with {:ok, module} <- ReqLLM.provider(provider_atom),
         true <- allowed_provider?(provider_id, module) do
      {:ok, provider_atom, module}
    else
      _other -> :error
    end
  end

  defp allowed_provider?(provider_id, module) do
    declared_provider_module?(provider_id, module) or bullx_registered?(module)
  end

  defp declared_provider_module?(provider_id, module) do
    BullX.LLM.PluginProviders.available_extensions()
    |> Enum.any?(fn extension ->
      extension_id(extension.id) == provider_id and extension.module == module
    end)
  end

  defp bullx_registered?(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.starts_with?(["Elixir.BullX.LLM.Providers.", "Elixir.ChineseLLMProvidersExtra."])
  end

  defp extension_id(id) when is_binary(id), do: id
  defp extension_id(id) when is_atom(id), do: Atom.to_string(id)
end
