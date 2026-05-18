defmodule Discord.CommandNormalizer do
  @moduledoc false

  @direct_commands ~w(preauth web_auth)

  @spec parse_text(String.t() | nil) ::
          {:eventbus, map()} | {:direct, map()} | {:ignore, :unsupported_command} | :not_command
  def parse_text(text) when is_binary(text) do
    with "/" <> rest <- String.trim_leading(text),
         [token | tail] <- String.split(rest, ~r/\s+/, parts: 2) do
      args = tail |> List.first() |> to_string() |> String.trim()
      classify(token, args, "slash_text")
    else
      _value -> :not_command
    end
  end

  def parse_text(_text), do: :not_command

  @spec parse_interaction(map()) :: {:eventbus, map()} | {:direct, map()} | {:ignore, :unsupported_command}
  def parse_interaction(%{} = interaction) do
    data = Map.get(interaction, "data") || %{}
    name = Map.get(data, "name")
    args = interaction_args(data)

    case is_binary(name) and name != "" do
      true -> classify(name, args, "provider_native", Map.get(data, "id"))
      false -> {:ignore, :unsupported_command}
    end
  end

  def parse_interaction(_interaction), do: {:ignore, :unsupported_command}

  defp classify(name, args, surface, provider_command_id \\ nil) do
    case canonical(name) do
      {:ok, command_name} when command_name in @direct_commands ->
        {:direct, %{name: command_name, args: args, surface: surface}}

      {:ok, command_name} ->
        {:eventbus,
         %{
           name: command_name,
           args: args,
           args_kind: args_kind(args, surface),
           surface: surface,
           provider_command_id: provider_command_id
         }}

      :error ->
        {:ignore, :unsupported_command}
    end
  end

  defp canonical("preauth"), do: {:ok, "preauth"}
  defp canonical("web_auth"), do: {:ok, "web_auth"}
  defp canonical("ask"), do: {:ok, "ask"}
  defp canonical(name), do: BullX.EventBus.CommandCatalog.canonical_command_name(name)

  defp interaction_args(%{"options" => options}) when is_list(options) do
    options
    |> Enum.map(fn option -> Map.get(option, "value") end)
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
  end

  defp interaction_args(_data), do: ""
  defp args_kind("", _surface), do: "none"
  defp args_kind(_args, "provider_native"), do: "options"
  defp args_kind(_args, _surface), do: "text"
end
