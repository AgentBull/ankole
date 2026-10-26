defmodule Ankole.Ash.AfterCommit do
  @moduledoc """
  Runs the declared publish function of a generic action after its commit.

  A generic action declares it with `after_commit({Module, :function})`. The
  function receives the action result. It runs only when the action succeeds,
  outside the transaction, so it can wake processes or call external systems.
  """
  use Ash.Resource.Preparation

  @impl true
  def supports(_opts), do: [Ash.ActionInput]

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :publish) do
      {:ok, {module, function}} when is_atom(module) and is_atom(function) -> {:ok, opts}
      _other -> {:error, "after_commit needs a {module, function} publish function"}
    end
  end

  @impl true
  def prepare(input, opts, _context) do
    {module, function} = Keyword.fetch!(opts, :publish)

    Ash.ActionInput.after_transaction(input, fn _input, result ->
      case result do
        {:ok, value} -> apply(module, function, [value])
        :ok -> apply(module, function, [nil])
        _error -> :ok
      end

      result
    end)
  end
end
