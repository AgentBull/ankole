defmodule BullXHarness.DefaultTemplate do
  @moduledoc false

  @source Path.expand("templates/SOUL.md", __DIR__)
  @external_resource @source
  @soul @source |> File.read!() |> String.trim()

  @spec soul() :: String.t()
  def soul, do: @soul
end
