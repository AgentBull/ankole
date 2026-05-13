defmodule BullX.Principals.LoginProviders do
  @moduledoc false

  alias BullX.Gateway.{JSON, SourceConfig, Sources}
  alias BullX.Plugins.Registry

  @extension_point :"bullx.principals.login_provider"

  @spec extension_point() :: atom()
  def extension_point, do: @extension_point

  @spec enabled() :: %{String.t() => BullX.Plugins.Extension.t()}
  def enabled do
    @extension_point
    |> Registry.enabled_extensions_for()
    |> Map.new(fn extension -> {to_id(extension.id), extension} end)
  end

  @spec fetch_impl(String.t() | atom()) ::
          {:ok, module(), map()} | {:error, :unknown_login_provider}
  def fetch_impl(adapter) do
    case Map.fetch(enabled(), to_id(adapter)) do
      {:ok, extension} -> {:ok, extension.module, extension.opts}
      :error -> {:error, :unknown_login_provider}
    end
  end

  @spec fetch(String.t()) ::
          {:ok, SourceConfig.t(), module(), map()}
          | {:error, :unknown_provider | :unknown_login_provider}
  def fetch(provider_id) when is_binary(provider_id) do
    with {:ok, source} <- source_for_provider(provider_id),
         {:ok, module, opts} <- fetch_impl(source.adapter) do
      {:ok, source, module, opts}
    end
  end

  @spec provider_ids() :: [String.t()]
  def provider_ids do
    Sources.enabled!()
    |> Enum.filter(&oidc_enabled?/1)
    |> Enum.map(& &1.channel_id)
  end

  defp source_for_provider(provider_id) do
    provider_id = String.downcase(provider_id)

    Sources.enabled!()
    |> Enum.find(fn source ->
      String.downcase(source.channel_id) == provider_id and oidc_enabled?(source)
    end)
    |> case do
      %SourceConfig{} = source -> {:ok, source}
      nil -> {:error, :unknown_provider}
    end
  end

  defp oidc_enabled?(%SourceConfig{config: config}) do
    case JSON.stringify_keys(config) do
      {:ok, %{"oidc" => %{"enabled" => true}}} -> true
      _other -> false
    end
  end

  defp to_id(id) when is_atom(id), do: id |> Atom.to_string() |> String.downcase()
  defp to_id(id) when is_binary(id), do: String.downcase(id)
end
