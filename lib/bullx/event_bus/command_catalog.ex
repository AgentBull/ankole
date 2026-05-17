defmodule BullX.EventBus.CommandCatalog do
  @moduledoc """
  Code-owned command catalog used by Channel Adapter normalization.

  Command names that reach EventBus routing are canonical English ids. Localized
  slash tokens are aliases that adapters normalize before they set
  `data.routing_facts.command_name`.
  """

  @system_commands [
    %{
      name: "command",
      slash: "/command",
      alias_key: "eventbus.commands.aliases.command",
      target_ref: "bullx.system.command_list",
      description: "list available system commands"
    },
    %{
      name: "status",
      slash: "/status",
      alias_key: "eventbus.commands.aliases.status",
      target_ref: "bullx.system.status",
      description: "show BullX runtime status, environment, and version"
    }
  ]

  @ai_agent_commands [
    %{
      name: "new",
      slash: "/new",
      alias_key: "eventbus.commands.aliases.new"
    }
  ]

  @commands @system_commands ++ @ai_agent_commands

  @spec system_catalog() :: [map()]
  def system_catalog, do: @system_commands

  @spec system_target_refs() :: [String.t()]
  def system_target_refs, do: Enum.map(@system_commands, & &1.target_ref)

  @spec canonical_command_name(String.t(), keyword()) :: {:ok, String.t()} | :error
  def canonical_command_name(command_name, opts \\ []) when is_binary(command_name) do
    normalized = normalize_command_name(command_name)

    cond do
      canonical_name?(normalized) ->
        {:ok, normalized}

      true ->
        fetch_localized_alias(normalized, opts)
    end
  end

  defp canonical_name?(command_name) do
    Enum.any?(@commands, &(&1.name == command_name))
  end

  defp fetch_localized_alias(normalized, opts) do
    Enum.find_value(@commands, :error, fn command ->
      case normalized in localized_aliases(command, opts) do
        true -> {:ok, command.name}
        false -> nil
      end
    end)
  end

  defp localized_aliases(command, opts) do
    command.alias_key
    |> BullX.I18n.translate(%{}, opts)
    |> case do
      {:ok, aliases} -> split_aliases(aliases)
      {:error, _reason} -> []
    end
  end

  defp split_aliases(aliases) do
    aliases
    |> String.split([",", "，", "\n"], trim: true)
    |> Enum.map(&normalize_command_name/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_command_name(command_name) do
    command_name
    |> String.trim()
    |> String.trim_leading("/")
    |> String.downcase()
  end
end
