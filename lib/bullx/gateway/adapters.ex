defmodule BullX.Gateway.Adapters do
  @moduledoc false

  alias BullX.Plugins.Registry

  @extension_point :"bullx.gateway.adapter"

  @spec enabled() :: %{String.t() => module()}
  def enabled do
    @extension_point
    |> Registry.enabled_extensions_for()
    |> Map.new(fn extension -> {to_id(extension.id), extension.module} end)
  end

  @spec fetch(String.t()) :: {:ok, module()} | {:error, :unknown_adapter}
  def fetch(adapter) when is_binary(adapter) do
    case Map.fetch(enabled(), String.downcase(adapter)) do
      {:ok, module} -> {:ok, module}
      :error -> :error
    end
    |> case do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_adapter}
    end
  end

  @spec extension_point() :: atom()
  def extension_point, do: @extension_point

  defp to_id(id) when is_atom(id), do: id |> Atom.to_string() |> String.downcase()
  defp to_id(id) when is_binary(id), do: String.downcase(id)
end
