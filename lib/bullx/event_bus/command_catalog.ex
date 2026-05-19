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
      description_key: "eventbus.commands.descriptions.command"
    },
    %{
      name: "status",
      slash: "/status",
      alias_key: "eventbus.commands.aliases.status",
      target_ref: "bullx.system.status",
      description_key: "eventbus.commands.descriptions.status"
    }
  ]

  @ai_agent_commands [
    %{
      name: "new",
      slash: "/new",
      alias_key: "eventbus.commands.aliases.new",
      description_key: "eventbus.commands.descriptions.new"
    },
    %{
      name: "compress",
      slash: "/compress",
      alias_key: "eventbus.commands.aliases.compress",
      description_key: "eventbus.commands.descriptions.compress"
    },
    %{
      name: "retry",
      slash: "/retry",
      alias_key: "eventbus.commands.aliases.retry",
      description_key: "eventbus.commands.descriptions.retry"
    },
    %{
      name: "steer",
      slash: "/steer",
      alias_key: "eventbus.commands.aliases.steer",
      description_key: "eventbus.commands.descriptions.steer"
    },
    %{
      name: "stop",
      slash: "/stop",
      alias_key: "eventbus.commands.aliases.stop",
      description_key: "eventbus.commands.descriptions.stop"
    },
    %{
      name: "undo",
      slash: "/undo",
      alias_key: "eventbus.commands.aliases.undo",
      description_key: "eventbus.commands.descriptions.undo"
    }
  ]

  @commands @system_commands ++ @ai_agent_commands

  @spec catalog() :: [map()]
  def catalog, do: @commands

  @spec system_catalog() :: [map()]
  def system_catalog, do: @system_commands

  @spec system_target_refs() :: [String.t()]
  def system_target_refs, do: Enum.map(@system_commands, & &1.target_ref)

  @spec display_slash(map(), keyword()) :: String.t()
  def display_slash(%{slash: slash} = command, opts \\ []) do
    command
    |> localized_aliases(opts)
    |> List.first()
    |> render_display_slash(slash)
  end

  @spec description(map(), keyword()) :: String.t()
  def description(%{description_key: key}, opts \\ []) do
    case BullX.I18n.translate(key, %{}, opts) do
      {:ok, description} -> description
      {:error, _reason} -> key
    end
  end

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

  defp render_display_slash(nil, slash), do: slash

  defp render_display_slash(alias, slash) do
    case "/" <> alias == slash do
      true -> slash
      false -> "/" <> alias <> " (" <> slash <> ")"
    end
  end

  defp normalize_command_name(command_name) do
    command_name
    |> String.trim()
    |> String.trim_leading("/")
    |> String.downcase()
  end
end
