defmodule BullxTelegram.CommandNormalizer do
  @moduledoc false

  @direct_commands ~w(root_init webauth command status)

  @spec parse(String.t() | nil, String.t() | nil) ::
          {:agent_command, map()}
          | {:direct, map()}
          | {:ignore, :unsupported_command}
          | :not_command
  def parse(text, bot_username) when is_binary(text) do
    with "/" <> rest <- String.trim_leading(text),
         [token | tail] <- String.split(rest, ~r/\s+/, parts: 2),
         true <- token != "",
         {:ok, command_name, addressed?} <- split_token(token, bot_username),
         true <- addressed? do
      args = tail |> List.first() |> to_string() |> String.trim()

      case canonical(command_name) do
        {:ok, name} when name in @direct_commands ->
          {:direct, %{name: name, args: args}}

        {:ok, name} ->
          {:agent_command, command(name, args)}

        :error ->
          {:agent_command, command(normalize_unknown(command_name), args)}
      end
    else
      false -> {:ignore, :unsupported_command}
      _value -> :not_command
    end
  end

  def parse(_text, _bot_username), do: :not_command

  defp split_token(token, nil), do: {:ok, token, true}

  defp split_token(token, bot_username) do
    case String.split(token, "@", parts: 2) do
      [name] ->
        {:ok, name, true}

      [name, suffix] ->
        {:ok, name, String.downcase(suffix) == String.downcase(bot_username)}
    end
  end

  defp canonical("root_init"), do: {:ok, "root_init"}
  defp canonical("webauth"), do: {:ok, "webauth"}
  defp canonical(name), do: BullX.AIAgent.CommandCatalog.canonical_command_name(name)

  defp command(name, args) do
    %{
      name: name,
      args: args,
      args_kind: if(args == "", do: "none", else: "text"),
      surface: "slash_text"
    }
  end

  defp normalize_unknown(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.trim_leading("/")
    |> String.downcase()
  end
end
