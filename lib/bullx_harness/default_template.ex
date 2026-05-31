defmodule BullXHarness.DefaultTemplate do
  @moduledoc """
  Reads embedded default setup templates used by the BullX harness.

  These templates seed the first Agent during setup. They are prompt material,
  not browser i18n strings, so the backend owns the source of truth.
  """

  @source Path.expand("templates/SOUL.md", __DIR__)
  @external_resource @source
  @soul @source |> File.read!() |> String.trim()

  @spec soul() :: String.t()
  def soul, do: @soul
end
