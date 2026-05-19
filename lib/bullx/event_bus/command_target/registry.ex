defmodule BullX.EventBus.CommandTarget.Registry do
  @moduledoc false

  alias BullX.EventBus.CommandCatalog
  alias BullX.EventBus.CommandTarget.SystemCommands

  @handlers %{
    "bullx.system.command_list" => SystemCommands,
    "bullx.system.status" => SystemCommands
  }

  @spec fetch_handler(String.t()) :: {:ok, module()} | {:error, term()}
  def fetch_handler(target_ref) when is_binary(target_ref) do
    handlers = Map.merge(@handlers, configured_handlers())

    case Map.fetch(handlers, target_ref) do
      {:ok, module} -> validate_handler(target_ref, module)
      :error -> {:error, {:command_handler_missing, target_ref}}
    end
  end

  @spec system_catalog() :: [map()]
  defdelegate system_catalog, to: CommandCatalog

  @spec command_catalog() :: [map()]
  defdelegate command_catalog, to: CommandCatalog, as: :catalog

  @spec display_slash(map(), keyword()) :: String.t()
  defdelegate display_slash(command, opts), to: CommandCatalog

  @spec description(map(), keyword()) :: String.t()
  defdelegate description(command, opts), to: CommandCatalog

  @spec system_target_refs() :: [String.t()]
  defdelegate system_target_refs, to: CommandCatalog

  defp configured_handlers do
    :bullx
    |> Application.get_env(:event_bus_command_handlers, %{})
    |> Map.new(fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
    end)
  end

  defp validate_handler(target_ref, module) when is_atom(module) do
    case function_exported?(module, :handle, 2) do
      true -> {:ok, module}
      false -> {:error, {:command_handler_invalid, target_ref, module}}
    end
  end

  defp validate_handler(target_ref, module),
    do: {:error, {:command_handler_invalid, target_ref, module}}
end
