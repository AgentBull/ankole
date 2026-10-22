defmodule Ankole.Credo.AshActions do
  @moduledoc "Checks Ash mutation filters and the action facade boundary."
  use Credo.Check, base_priority: :high, category: :warning

  @impl true
  def run(source_file, params) do
    if String.ends_with?(source_file.filename, "/ankole/ash.ex") do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  defp traverse(
         {{:., _, [{:__aliases__, _, [:Ash]}, name]}, meta, _args} = ast,
         issues,
         issue_meta
       )
       when name in [:bulk_create, :bulk_update, :bulk_destroy] do
    {ast,
     [issue(issue_meta, meta[:line], "Use Ankole.Ash for synchronous bulk actions.") | issues]}
  end

  defp traverse(
         {{:., _, [{:__aliases__, _, [:Ash, :Changeset]}, name]}, meta, _args} = ast,
         issues,
         issue_meta
       )
       when name in [:before_transaction, :after_transaction, :around_transaction] do
    {ast,
     [issue(issue_meta, meta[:line], "Keep transaction effects in their domain owner.") | issues]}
  end

  defp traverse({action, _meta, [_name | args]} = ast, issues, issue_meta)
       when action in [:update, :destroy, :in_tx_update, :atomic_in_tx_update] do
    options = List.last(args)

    if is_list(options) and Keyword.keyword?(options),
      do: {ast, mutation_filters(options[:do], issues, issue_meta)},
      else: {ast, issues}
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp mutation_filters({:change, _meta, _args}, issues, _issue_meta), do: issues

  defp mutation_filters({:filter, meta, [_expression]}, issues, issue_meta) do
    [issue(issue_meta, meta[:line], "Apply mutation filters with change(filter(...)).") | issues]
  end

  defp mutation_filters(tuple, issues, issue_meta) when is_tuple(tuple),
    do: mutation_filters(Tuple.to_list(tuple), issues, issue_meta)

  defp mutation_filters(list, issues, issue_meta) when is_list(list),
    do: Enum.reduce(list, issues, &mutation_filters(&1, &2, issue_meta))

  defp mutation_filters(_node, issues, _issue_meta), do: issues

  defp issue(issue_meta, line, message),
    do: format_issue(issue_meta, line_no: line, message: message)
end
