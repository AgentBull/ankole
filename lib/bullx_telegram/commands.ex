defmodule BullXTelegram.Commands do
  @moduledoc """
  Telegram command menu registration.
  """

  alias BullXTelegram.{Config, Error}

  @commands [
    %{command: "ping", description: "Check BullX connectivity"},
    %{command: "preauth", description: "Link this Telegram account"},
    %{command: "web_auth", description: "Create a BullX web login code"},
    %{command: "ask", description: "Ask BullX in this chat"}
  ]

  @spec desired_commands() :: [map()]
  def desired_commands, do: @commands

  @spec sync(Config.t()) :: {:ok, :off | map() | list()} | {:error, map()}
  def sync(%Config{commands: %{sync_policy: "off"}}), do: {:ok, :off}

  def sync(%Config{} = config) do
    case Config.request(config, "setMyCommands", commands: {:json, desired_commands()}) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, Error.map(error)}
    end
  end
end
