defmodule Ankole.AgentWorkers.Changes.StateClock do
  @moduledoc false
  import Ash.Expr

  def expression(target) do
    expr(
      if state != ^target and
           not (state in [:starting, :stale] and ^target in [:starting, :stale]),
         do: fragment("clock_timestamp()"),
         else: state_changed_at
    )
  end
end
