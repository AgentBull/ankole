Code.require_file("persistence_boundary.ex", __DIR__)

defmodule Ankole.Credo.AshBoundary do
  @moduledoc """
  Keeps persistence calls at their owners.

  Framework errors and bulk results stay in `Ankole.Ash`, `Ankole.Errors`, and
  `AnkoleWeb.ConsoleErrors`. Ecto writes, Ecto row locks, and `Repo`
  transactions stay in the registered exception modules. Web, plugin, and
  application code calls domain code interfaces instead of Ash. Each file can
  keep the reviewed count of `test/ankole/persistence_boundary.exs`; the
  boundary test removes a count when its file no longer needs it.
  """
  use Credo.Check, base_priority: :high, category: :warning

  alias Ankole.Credo.PersistenceBoundary

  @kinds [
    :bulk_result,
    :error_class,
    :ash_error_match,
    :ecto_write,
    :ecto_lock,
    :repo_transact,
    :consumer_ash
  ]

  @messages %{
    bulk_result: "Decode bulk results with Ankole.Ash.update_where/destroy_where/update_atomic.",
    error_class: "Give declared errors through Ankole.Errors; do not build Ash error classes.",
    ash_error_match: "Get a domain reason with Ankole.Errors.reason/1 instead of matching Ash errors.",
    ecto_write: "Write a resource table through its Ash action; Ecto writes stay in exception modules.",
    ecto_lock: "Lock a resource row with Ash.Query.lock/2 and Ankole.Ash.read(lock_identity: ...).",
    repo_transact: "Let a generic action own the transaction; Repo.transact stays in exception modules.",
    consumer_ash: "Call the owning domain's code interface instead of Ash from this layer."
  }

  @impl true
  def run(source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> Credo.SourceFile.ast()
    |> PersistenceBoundary.excess(source_file.filename, @kinds)
    |> Enum.map(fn {occurrence, allowed} ->
      format_issue(issue_meta,
        line_no: occurrence.line,
        message: "#{@messages[occurrence.kind]} (reviewed count: #{allowed})"
      )
    end)
  end
end
