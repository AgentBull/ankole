defmodule BullxTelegram.Commands do
  @moduledoc """
  Telegram bot command menu sync via `setMyCommands`.

  Telegram's `setMyCommands` replaces the entire command list, so the policy
  is either `"replace"` (push the BullX command set) or `"off"` (leave the
  operator-managed list alone).
  """

  alias BullxTelegram.{Error, Source}

  @default_commands [
    %{command: "ping", description_key: "gateway.telegram.commands.ping"},
    %{command: "preauth", description_key: "gateway.telegram.commands.preauth"},
    %{command: "web_auth", description_key: "gateway.telegram.commands.web_auth"}
  ]

  @spec sync(Source.t()) :: :ok | {:error, map()}
  def sync(%Source{commands: %{"sync_policy" => "off"}}), do: :ok

  def sync(%Source{} = source) do
    case Source.request(source, "setMyCommands", commands: encoded_commands()) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, Error.map(error)}
    end
  end

  @spec command_definitions() :: [%{command: String.t(), description: String.t()}]
  def command_definitions do
    Enum.map(@default_commands, fn %{command: command, description_key: key} ->
      %{command: command, description: BullX.I18n.t(key)}
    end)
  end

  defp encoded_commands do
    {:json, command_definitions()}
  end
end
