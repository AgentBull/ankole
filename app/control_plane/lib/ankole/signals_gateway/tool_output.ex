defmodule Ankole.SignalsGateway.ToolOutput do
  @moduledoc false

  alias Ankole.JSON

  def decode(output) when is_binary(output) do
    case output |> String.trim() |> JSON.decode() do
      {:ok, decoded} -> decoded
      {:error, _reason} -> nil
    end
  end

  def decode(output) when is_map(output), do: output
  def decode(_output), do: nil
end
