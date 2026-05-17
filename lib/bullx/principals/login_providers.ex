defmodule BullX.Principals.LoginProviders do
  @moduledoc false

  alias BullX.Plugins.Extension

  @extension_point :"bullx.principals.login_provider"

  @spec extension_point() :: atom()
  def extension_point, do: @extension_point

  @spec enabled_providers(GenServer.server()) :: {:ok, [Extension.t()]} | {:error, term()}
  def enabled_providers(server \\ BullX.Plugins.Registry) do
    @extension_point
    |> BullX.Plugins.enabled_extensions_for(server)
    |> validate_extensions()
  end

  @spec provider_ids(GenServer.server()) :: [String.t()]
  def provider_ids(server \\ BullX.Plugins.Registry) do
    with {:ok, providers} <- enabled_providers(server) do
      providers
      |> Enum.flat_map(&source_ids_for/1)
      |> Enum.uniq()
      |> Enum.sort()
    else
      {:error, _reason} -> []
    end
  end

  @spec authorization_url(String.t(), map(), GenServer.server()) ::
          {:ok, %{url: String.t(), state: map()}} | {:error, :not_found | term()}
  def authorization_url(provider_id, request, server \\ BullX.Plugins.Registry)
      when is_binary(provider_id) and is_map(request) do
    with {:ok, provider, source} <- find_provider_source(provider_id, server) do
      provider.module.authorization_url(source, request)
    end
  end

  @spec callback(String.t(), map(), map(), GenServer.server()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def callback(provider_id, params, state, server \\ BullX.Plugins.Registry)
      when is_binary(provider_id) and is_map(params) and is_map(state) do
    with {:ok, provider, source} <- find_provider_source(provider_id, server) do
      provider.module.callback(source, params, state)
    end
  end

  @spec state_ttl_seconds(String.t(), GenServer.server()) :: pos_integer()
  def state_ttl_seconds(provider_id, server \\ BullX.Plugins.Registry) do
    with {:ok, provider, source} <- find_provider_source(provider_id, server),
         true <- function_exported?(provider.module, :state_ttl_seconds, 1),
         ttl when is_integer(ttl) and ttl > 0 <- provider.module.state_ttl_seconds(source) do
      ttl
    else
      _other -> 600
    end
  end

  defp find_provider_source(provider_id, server) do
    with {:ok, providers} <- enabled_providers(server) do
      providers
      |> Enum.find_value(&maybe_fetch_source(&1, provider_id))
      |> case do
        nil -> {:error, :not_found}
        {provider, source} -> {:ok, provider, source}
      end
    end
  end

  defp maybe_fetch_source(%Extension{} = provider, provider_id) do
    cond do
      function_exported?(provider.module, :fetch_source, 1) ->
        case provider.module.fetch_source(provider_id) do
          {:ok, source} -> {provider, source}
          {:error, _reason} -> nil
        end

      normalize_id(provider.id) == provider_id ->
        {provider, %{id: provider_id}}

      true ->
        nil
    end
  end

  defp source_ids_for(%Extension{} = provider) do
    case function_exported?(provider.module, :provider_ids, 0) do
      true -> provider.module.provider_ids()
      false -> [normalize_id(provider.id)]
    end
  rescue
    _exception -> [normalize_id(provider.id)]
  end

  defp validate_extensions(extensions) do
    extensions
    |> Enum.reduce_while({:ok, []}, fn extension, {:ok, acc} ->
      case valid_extension?(extension) do
        true -> {:cont, {:ok, [extension | acc]}}
        false -> {:halt, {:error, {:invalid_login_provider, extension.id, extension.module}}}
      end
    end)
    |> case do
      {:ok, providers} -> {:ok, Enum.reverse(providers)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_extension?(%Extension{module: module}) do
    Code.ensure_loaded?(module) and function_exported?(module, :authorization_url, 2) and
      function_exported?(module, :callback, 3)
  end

  defp normalize_id(id) when is_atom(id), do: Atom.to_string(id)
  defp normalize_id(id) when is_binary(id), do: id
end
