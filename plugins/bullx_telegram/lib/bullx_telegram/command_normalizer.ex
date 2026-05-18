defmodule BullxTelegram.CommandNormalizer do
  @moduledoc false

  @direct_commands ~w(preauth web_auth)

  @spec parse(String.t() | nil, String.t() | nil) ::
          {:eventbus, map()} | {:direct, map()} | {:ignore, :unsupported_command} | :not_command
  def parse(text, bot_username) when is_binary(text) do
    with "/" <> rest <- String.trim_leading(text),
         [token | tail] <- String.split(rest, ~r/\s+/, parts: 2),
         {:ok, command_name, addressed?} <- split_token(token, bot_username),
         true <- addressed? do
      args = tail |> List.first() |> to_string() |> String.trim()

      case canonical(command_name) do
        {:ok, name} when name in @direct_commands ->
          {:direct, %{name: name, args: args}}

        {:ok, name} ->
          {:eventbus,
           %{
             name: name,
             args: args,
             args_kind: if(args == "", do: "none", else: "text"),
             surface: "slash_text"
           }}

        :error ->
          {:ignore, :unsupported_command}
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

  defp canonical("preauth"), do: {:ok, "preauth"}
  defp canonical("web_auth"), do: {:ok, "web_auth"}
  defp canonical(name), do: BullX.EventBus.CommandCatalog.canonical_command_name(name)
end
