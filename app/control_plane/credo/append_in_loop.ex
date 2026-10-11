defmodule Ankole.Credo.AppendInLoop do
  @moduledoc "Checks single-item append while accumulating a list in Enum or Stream."
  use Credo.Check, base_priority: :high, category: :refactor

  @impl true
  def run(source_file, params) do
    lines = Credo.Code.prewalk(source_file, &collect/2, MapSet.new())

    source_file
    |> Credo.Check.Refactor.AppendSingleItem.run(params)
    |> Enum.filter(&MapSet.member?(lines, &1.line_no))
    |> Enum.map(&%{&1 | check: __MODULE__, priority: 10})
  end

  defp collect({{:., _, [{:__aliases__, _, [module]}, function]}, _, args} = ast, lines)
       when module in [:Enum, :Stream] and
              function in [:reduce, :reduce_while, :map_reduce, :scan, :transform] do
    callbacks = Enum.filter(args, &match?({:fn, _, _}, &1))
    {ast, Enum.reduce(callbacks, lines, &append_lines/2)}
  end

  defp collect(ast, lines), do: {ast, lines}

  defp append_lines(callback, lines) do
    # A fixed path prefix from outside the callback is not its accumulator.
    # Bindings inside the callback include case/with patterns and assignments.
    {_, bindings} =
      Macro.prewalk(callback, MapSet.new(), fn
        {:->, _, [patterns, _]} = ast, names -> {ast, bind(patterns, names)}
        {:=, _, [pattern, _]} = ast, names -> {ast, bind(pattern, names)}
        {:<-, _, [pattern, _]} = ast, names -> {ast, bind(pattern, names)}
        ast, names -> {ast, names}
      end)

    {_, lines} =
      Macro.prewalk(callback, lines, fn
        {:++, meta, [left, [_]]} = ast, lines ->
          if local?(left, bindings), do: {ast, MapSet.put(lines, meta[:line])}, else: {ast, lines}

        ast, lines ->
          {ast, lines}
      end)

    lines
  end

  defp bind(pattern, names) do
    {_, names} =
      Macro.prewalk(pattern, names, fn
        {name, _, context} = ast, names when is_atom(name) and is_atom(context) ->
          {ast, MapSet.put(names, name)}

        ast, names ->
          {ast, names}
      end)

    names
  end

  defp local?({:&, _, [index]}, _names) when is_integer(index), do: true

  defp local?({name, _, context}, names) when is_atom(name) and is_atom(context),
    do: MapSet.member?(names, name)

  defp local?(_expression, _names), do: false
end
