defmodule BullX.LLM.ProviderRegistry do
  @moduledoc false

  @spec fetch(String.t()) ::
          {:ok, atom(), module()} | {:error, {:unknown_req_llm_provider, String.t()}}
  def fetch(provider_id) when is_binary(provider_id) do
    case find_provider_atom(provider_id) do
      {:ok, provider_atom} ->
        case ReqLLM.provider(provider_atom) do
          {:ok, module} -> {:ok, provider_atom, module}
          {:error, _reason} -> {:error, {:unknown_req_llm_provider, provider_id}}
        end

      :error ->
        {:error, {:unknown_req_llm_provider, provider_id}}
    end
  end

  @spec known?(String.t()) :: boolean()
  def known?(provider_id) when is_binary(provider_id) do
    match?({:ok, _provider_atom}, find_provider_atom(provider_id))
  end

  def known?(_provider_id), do: false

  defp find_provider_atom(provider_id) do
    ReqLLM.Providers.list()
    |> Enum.find(&(Atom.to_string(&1) == provider_id))
    |> case do
      nil -> :error
      provider_atom -> {:ok, provider_atom}
    end
  end
end
