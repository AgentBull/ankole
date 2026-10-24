Code.require_file("persistence_boundary.ex", __DIR__)

defmodule Ankole.Credo.AshBoundary do
  @moduledoc """
  Keeps persistence calls at their owners.

  Framework errors, bulk actions, bulk results, and transaction hooks stay in
  `Ankole.Ash`, `Ankole.Errors`, and `AnkoleWeb.ConsoleErrors`. Ecto writes,
  Ecto row locks, and `Repo` transactions stay in the registered exception
  modules. Web, plugin, and application code calls domain code interfaces
  instead of Ash. `test/ankole/persistence_boundary.exs` lists the exception
  modules.

  An update or destroy action applies its filter with `change(filter(...))`.
  A bare `filter(...)` in a mutation builds a change and drops it.
  """
  use Credo.Check, base_priority: :high, category: :warning

  alias Ankole.Credo.PersistenceBoundary

  @kinds [
    :bulk_result,
    :error_class,
    :ash_error_match,
    :ash_direct,
    :ash_bulk,
    :transaction_hook,
    :ecto_write,
    :ecto_lock,
    :repo_transact,
    :consumer_ash
  ]

  @messages %{
    bulk_result: "Decode bulk results with Ankole.Ash.update_where/destroy_where/update_atomic.",
    error_class: "Give declared errors through Ankole.Errors; do not build Ash error classes.",
    ash_error_match:
      "Get a domain reason with Ankole.Errors.reason/1 instead of matching Ash errors.",
    ash_direct: "Execute Ash queries, changesets, and actions through Ankole.Ash.",
    ash_bulk: "Use Ankole.Ash for synchronous bulk actions.",
    transaction_hook: "Let the top-level transaction own transaction effects (after_commit).",
    ecto_write:
      "Write a resource table through its Ash action; Ecto writes stay in exception modules.",
    ecto_lock:
      "Lock a resource row with Ash.Query.lock/2 and Ankole.Ash.read(lock_identity: ...).",
    repo_transact:
      "Own the transaction in the domain with Repo.transact_top_level or a generic action; Repo.transact stays in exception modules.",
    consumer_ash: "Call the owning domain's code interface instead of Ash from this layer."
  }

  @impl true
  def run(source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    ast = Credo.SourceFile.ast(source_file)

    boundary =
      ast
      |> PersistenceBoundary.crossings(source_file.filename, @kinds)
      |> Enum.map(fn occurrence ->
        format_issue(issue_meta, line_no: occurrence.line, message: @messages[occurrence.kind])
      end)

    {_ast, filters} = Macro.prewalk(ast, [], &mutation(&1, &2, issue_meta))
    boundary ++ Enum.reverse(filters)
  end

  defp mutation({action, _meta, [_name | args]} = ast, issues, issue_meta)
       when action in [:update, :destroy] do
    options = List.last(args)

    if is_list(options) and Keyword.keyword?(options),
      do: {ast, mutation_filters(options[:do], issues, issue_meta)},
      else: {ast, issues}
  end

  defp mutation(ast, issues, _issue_meta), do: {ast, issues}

  defp mutation_filters({:change, _meta, _args}, issues, _issue_meta), do: issues

  defp mutation_filters({:filter, meta, [_expression]}, issues, issue_meta) do
    [
      format_issue(issue_meta,
        line_no: meta[:line],
        message: "Apply mutation filters with change(filter(...))."
      )
      | issues
    ]
  end

  defp mutation_filters(tuple, issues, issue_meta) when is_tuple(tuple),
    do: mutation_filters(Tuple.to_list(tuple), issues, issue_meta)

  defp mutation_filters(list, issues, issue_meta) when is_list(list),
    do: Enum.reduce(list, issues, &mutation_filters(&1, &2, issue_meta))

  defp mutation_filters(_node, issues, _issue_meta), do: issues
end
