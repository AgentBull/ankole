defmodule Ankole.BrainSourceConnectorFixture do
  @moduledoc false

  @behaviour Ankole.Brain.SourceConnector

  @impl true
  def availability(_reference), do: {:ok, :available}

  @impl true
  def revision(_reference), do: {:ok, "fixture-revision"}

  @impl true
  def export(_reference) do
    {:ok, %{title: "Fixture source", markdown: "Fixture body", url: nil}}
  end
end
