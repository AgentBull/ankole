defmodule BullxTelegram.Commands do
  @moduledoc false

  @commands [
    %{"command" => "preauth", "description" => "Link this Telegram account to BullX"},
    %{"command" => "webauth", "description" => "Create a BullX web login code"},
    %{"command" => "command", "description" => "List BullX commands"},
    %{"command" => "status", "description" => "Show BullX status"}
  ]

  @spec sync(BullxTelegram.Source.t()) :: :ok | {:error, map()}
  def sync(%BullxTelegram.Source{commands: %{"sync_policy" => "off"}}), do: :ok

  def sync(%BullxTelegram.Source{} = source) do
    case BullxTelegram.Source.request(source, "setMyCommands", %{"commands" => @commands}) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, BullxTelegram.Error.map(error)}
    end
  end
end
