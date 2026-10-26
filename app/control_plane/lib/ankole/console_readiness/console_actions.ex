defmodule Ankole.ConsoleReadiness.ConsoleActions do
  @moduledoc "Reads the deployment readiness snapshot from its owner."
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context), do: {:ok, Ankole.ConsoleReadiness.snapshot()}
end
