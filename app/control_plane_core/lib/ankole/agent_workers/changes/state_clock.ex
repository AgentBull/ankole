defmodule Ankole.AgentWorkers.Changes.StateClock do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context),
    do:
      Ash.Changeset.atomic_update(
        changeset,
        :state_changed_at,
        expression(Keyword.fetch!(opts, :target))
      )

  @impl true
  def atomic(_changeset, opts, _context),
    do: {:atomic, %{state_changed_at: expression(Keyword.fetch!(opts, :target))}}

  defp expression(target) do
    expr(
      if state != ^target and
           not (state in [:starting, :stale] and ^target in [:starting, :stale]),
         do: fragment("clock_timestamp()"),
         else: state_changed_at
    )
  end
end
