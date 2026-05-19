defmodule Discord.CommandNormalizer do
  @moduledoc false

  @direct_commands ~w(preauth webauth)

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

  @spec parse_interaction(map()) :: {:eventbus, map()} | {:direct, map()} | {:ignore, atom()}
  def parse_interaction(%{} = interaction) do
    with true <- application_command_interaction?(interaction),
         {:ok, data} <- interaction_data(interaction),
         {:ok, name} <- interaction_name(data),
         {:ok, args} <- interaction_args(data, name) do
      classify(name, args, "provider_native", Map.get(data, "id"))
    else
      false -> {:ignore, :unsupported_interaction}
      {:error, reason} -> {:ignore, reason}
    end
  end

  def parse_interaction(_interaction), do: {:ignore, :unsupported_command}

  defp application_command_interaction?(%{"type" => type}) do
    type in [2, "2", "APPLICATION_COMMAND", "application_command"]
  end

  defp application_command_interaction?(_interaction), do: false

  defp interaction_data(interaction) do
    data = Map.get(interaction, "data") || %{}

    case data do
      %{} -> {:ok, data}
      _data -> {:error, :unsupported_command}
    end
  end

  defp interaction_name(data) do
    case Map.get(data, "name") do
      name when is_binary(name) and name != "" -> {:ok, name}
      _name -> {:error, :unsupported_command}
    end
  end

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
  defp canonical("webauth"), do: {:ok, "webauth"}
  defp canonical("ask"), do: {:ok, "ask"}
  defp canonical(name), do: BullX.EventBus.CommandCatalog.canonical_command_name(name)

  defp interaction_args(%{"options" => options}, "ask") when is_list(options) do
    case prompt_option(options) do
      prompt when is_binary(prompt) and prompt != "" -> {:ok, prompt}
      _prompt -> {:error, :missing_required_prompt}
    end
  end

  defp interaction_args(_data, "ask"), do: {:error, :missing_required_prompt}

  defp interaction_args(%{"options" => options}, _name) when is_list(options) do
    options
    |> Enum.map(fn option -> Map.get(option, "value") end)
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> then(&{:ok, &1})
  end

  defp interaction_args(_data, _name), do: {:ok, ""}

  defp prompt_option(options) do
    Enum.find_value(options, fn
      %{"name" => "prompt", "value" => value} when is_binary(value) ->
        value |> String.trim()

      _option ->
        nil
    end)
  end

  defp args_kind("", _surface), do: "none"
  defp args_kind(_args, "provider_native"), do: "options"
  defp args_kind(_args, _surface), do: "text"
end
