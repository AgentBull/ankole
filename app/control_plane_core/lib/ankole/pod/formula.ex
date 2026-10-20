defmodule Ankole.Pod.Formula do
  @moduledoc false

  @precedence %{
    "||" => 1,
    "&&" => 2,
    "=" => 3,
    "==" => 3,
    "!=" => 3,
    "<>" => 3,
    ">" => 3,
    ">=" => 3,
    "<" => 3,
    "<=" => 3,
    "&" => 4,
    "+" => 5,
    "-" => 5,
    "*" => 6,
    "/" => 6,
    "%" => 6
  }
  @readonly ~w(formula created_at updated_at created_by updated_by)

  def readonly?(field), do: to_string(field.type) in @readonly

  def type(field) do
    case to_string(field.type) do
      "number" -> :number
      "auto_number" -> :number
      "checkbox" -> :boolean
      "datetime" -> :datetime
      type when type in ~w(created_at updated_at) -> :datetime
      type when type in ~w(user attachment link) -> :array
      "select" -> if field.config["multiple"], do: :array, else: :text
      "formula" -> String.to_existing_atom(field.config["result_type"])
      _ -> :text
    end
  end

  def prepare(field, fields) do
    if field.type == :formula do
      source =
        Ankole.Attrs.get(field.config, :source, Ankole.Attrs.get(field.config, :formula, ""))

      with {:ok, tokens} <- lex(source, []),
           {:ok, ast, []} <- parse_expression(tokens, 0, fields) do
        {:ok, %{field | config: Map.merge(field.config, %{"source" => source, "ast" => ast})}}
      else
        _ -> {:error, :invalid_formula}
      end
    else
      {:ok, field}
    end
  end

  def validate_all(fields) do
    with {:ok, ordered} <- dependency_order(fields) do
      Enum.reduce_while(ordered, {:ok, [], %{}}, fn field, {:ok, checked, known} ->
        if field.type == :formula do
          case infer(field.config["ast"], known) do
            {:ok, type, volatile} ->
              field = %{
                field
                | config:
                    Map.merge(field.config, %{
                      "result_type" => to_string(type),
                      "volatile" => volatile
                    })
              }

              {:cont, {:ok, [field | checked], Map.put(known, field.id, field)}}

            error ->
              {:halt, error}
          end
        else
          {:cont, {:ok, [field | checked], Map.put(known, field.id, field)}}
        end
      end)
      |> case do
        {:ok, checked, _known} -> {:ok, Enum.reverse(checked)}
        error -> error
      end
    end
  end

  def references?(field, id), do: field.type == :formula and referenced?(field.config["ast"], id)

  def remap_references(%{"kind" => "field", "id" => id} = ast, mapping),
    do: %{ast | "id" => Map.fetch!(mapping, id)}

  def remap_references(ast, mapping) when is_map(ast),
    do: Map.new(ast, fn {key, value} -> {key, remap_references(value, mapping)} end)

  def remap_references(list, mapping) when is_list(list),
    do: Enum.map(list, &remap_references(&1, mapping))

  def remap_references(value, _mapping), do: value

  def expression(%{type: :formula} = field, fields, params) do
    with {:ok, dependencies} <- dependency_order(fields, [field.id]),
         {:ok, ordered} <- validate_all(dependencies),
         {:ok, plan, params} <- expressions(ordered, params) do
      sql =
        "(WITH #{Enum.join(Enum.reverse(plan.ctes), ", ")} SELECT #{plan.expressions[field.id]})"

      {:ok, sql, type(plan.definitions[field.id]), params}
    end
  end

  def expression(field, _fields, params) do
    with {:ok, sql, params} <- sql_field(field, nil, params),
         do: {:ok, sql, type(field), params}
  end

  defp expressions(fields, params) do
    initial = %{definitions: Map.new(fields, &{&1.id, &1}), expressions: %{}, ctes: []}

    Enum.reduce_while(fields, {:ok, initial, params}, fn field, {:ok, plan, params} ->
      case sql_field(field, plan, params) do
        {:ok, sql, params} ->
          {sql, ctes} =
            if field.type == :formula do
              name = "pod_formula_#{map_size(plan.expressions)}"
              # Each dependency is read once, only when a selected branch needs it.
              {"(SELECT value FROM #{name})",
               ["#{name} AS MATERIALIZED (SELECT #{sql} AS value)" | plan.ctes]}
            else
              {sql, plan.ctes}
            end

          {:cont,
           {:ok, %{plan | expressions: Map.put(plan.expressions, field.id, sql), ctes: ctes},
            params}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp dependency_order(fields, roots \\ nil) do
    definitions = Map.new(fields, &{&1.id, &1})

    Enum.reduce_while(roots || Enum.map(fields, & &1.id), {:ok, [], MapSet.new()}, fn id, acc ->
      case visit(id, definitions, MapSet.new(), acc) do
        {:ok, _, _} = result -> {:cont, result}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, ordered, _done} -> {:ok, Enum.reverse(ordered)}
      error -> error
    end
  end

  defp visit(id, definitions, visiting, {:ok, _ordered, done} = acc) do
    cond do
      MapSet.member?(done, id) ->
        acc

      MapSet.member?(visiting, id) ->
        {:error, :formula_cycle}

      not Map.has_key?(definitions, id) ->
        {:error, :unknown_formula_field}

      true ->
        field = definitions[id]
        refs = if field.type == :formula, do: reference_ids(field.config["ast"]), else: []

        Enum.reduce_while(Enum.uniq(refs), acc, fn ref, acc ->
          case visit(ref, definitions, MapSet.put(visiting, id), acc) do
            {:ok, _, _} = result -> {:cont, result}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, ordered, done} -> {:ok, [field | ordered], MapSet.put(done, id)}
          error -> error
        end
    end
  end

  defp reference_ids(%{"kind" => "field", "id" => id}), do: [id]
  defp reference_ids(ast) when is_map(ast), do: Enum.flat_map(Map.values(ast), &reference_ids/1)
  defp reference_ids(list) when is_list(list), do: Enum.flat_map(list, &reference_ids/1)
  defp reference_ids(_), do: []

  def refresh_sources(fields, %{name: name}, %{name: name}), do: fields

  def refresh_sources(fields, old, _candidate) do
    Enum.map(fields, fn field ->
      if references?(field, old.id),
        do: %{
          field
          | config: Map.put(field.config, "source", source(field.config["ast"], fields))
        },
        else: field
    end)
  end

  defp source(%{"kind" => "field", "id" => id}, fields) do
    name =
      Enum.find(fields, &(&1.id == id)).name
      |> String.replace("\\", "\\\\")
      |> String.replace("]", "\\]")

    "[#{name}]"
  end

  defp source(%{"kind" => "literal", "value" => value}, _fields), do: Torque.encode!(value)
  defp source(%{"kind" => "number", "value" => text}, _fields), do: text

  defp source(%{"kind" => "unary", "op" => op, "arg" => arg}, fields),
    do: "#{op}(#{source(arg, fields)})"

  defp source(%{"kind" => "binary", "op" => op, "left" => left, "right" => right}, fields),
    do: "(#{source(left, fields)} #{op} #{source(right, fields)})"

  defp source(%{"kind" => "call", "name" => name, "args" => args}, fields),
    do: "#{name}(#{Enum.map_join(args, ", ", &source(&1, fields))})"

  def bind(params, value) do
    case Enum.find_index(params, &(&1 === value)) do
      nil -> {"$#{length(params) + 1}", params ++ [value]}
      index -> {"$#{index + 1}", params}
    end
  end

  defp lex("", tokens), do: {:ok, Enum.reverse(tokens)}

  defp lex(source, tokens) when is_binary(source) do
    source = String.trim_leading(source)

    cond do
      source == "" ->
        {:ok, Enum.reverse(tokens)}

      match = Regex.run(~r/^\[((?:\\[\\\]]|[^\\\]])+)\]/u, source) ->
        name = Regex.replace(~r/\\([\\\]])/u, Enum.at(match, 1), fn _match, name -> name end)
        lex(drop(source, hd(match)), [{:field, name} | tokens])

      match = Regex.run(~r/^"(?:[^"\\]|\\.)*"/u, source) ->
        case Torque.decode(hd(match)) do
          {:ok, value} -> lex(drop(source, hd(match)), [{:literal, value} | tokens])
          _ -> {:error, :invalid_formula}
        end

      match = Regex.run(~r/^\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/, source) ->
        text = hd(match)
        lex(drop(source, text), [{:number, text} | tokens])

      match = Regex.run(~r/^[A-Za-z_][A-Za-z_0-9]*/, source) ->
        lex(drop(source, hd(match)), [{:name, String.upcase(hd(match))} | tokens])

      match = Regex.run(~r/^(?:&&|\|\||>=|<=|!=|==|<>|[+*\/%&=><!(),-])/, source) ->
        lex(drop(source, hd(match)), [hd(match) | tokens])

      true ->
        {:error, :invalid_formula}
    end
  end

  defp lex(_, _), do: {:error, :invalid_formula}

  defp drop(source, token),
    do: binary_part(source, byte_size(token), byte_size(source) - byte_size(token))

  defp parse_expression(tokens, min, fields) do
    with {:ok, left, rest} <- primary(tokens, fields), do: infix(left, rest, min, fields)
  end

  defp infix(left, [op | rest] = tokens, min, fields) when is_binary(op) do
    case @precedence[op] do
      priority when is_integer(priority) and priority >= min ->
        with {:ok, right, tail} <- parse_expression(rest, priority + 1, fields),
             do:
               infix(
                 %{"kind" => "binary", "op" => op, "left" => left, "right" => right},
                 tail,
                 min,
                 fields
               )

      _ ->
        {:ok, left, tokens}
    end
  end

  defp infix(left, tokens, _min, _fields), do: {:ok, left, tokens}

  defp primary([{:literal, value} | rest], _fields),
    do: {:ok, %{"kind" => "literal", "value" => value}, rest}

  defp primary([{:number, text} | rest], _fields),
    do: {:ok, %{"kind" => "number", "value" => text}, rest}

  defp primary([{:field, name} | rest], fields) do
    case Enum.find(fields, &(&1.name == name)) do
      nil -> {:error, :unknown_formula_field}
      field -> {:ok, %{"kind" => "field", "id" => field.id}, rest}
    end
  end

  defp primary([op | rest], fields) when op in ["-", "+", "!"] do
    with {:ok, arg, tail} <- parse_expression(rest, 7, fields),
         do: {:ok, %{"kind" => "unary", "op" => op, "arg" => arg}, tail}
  end

  defp primary(["(" | rest], fields) do
    with {:ok, ast, [")" | tail]} <- parse_expression(rest, 0, fields),
         do: {:ok, ast, tail},
         else: (_ -> {:error, :invalid_formula})
  end

  defp primary([{:name, name}, "(" | rest], fields) do
    with {:ok, args, tail} <- arguments(rest, fields, []),
         do: {:ok, %{"kind" => "call", "name" => name, "args" => args}, tail}
  end

  defp primary([{:name, name} | rest], _fields) when name in ["TRUE", "FALSE"],
    do: {:ok, %{"kind" => "literal", "value" => name == "TRUE"}, rest}

  defp primary(_, _fields), do: {:error, :invalid_formula}
  defp arguments([")" | rest], _fields, args), do: {:ok, Enum.reverse(args), rest}

  defp arguments(tokens, fields, args) do
    with {:ok, ast, tail} <- parse_expression(tokens, 0, fields) do
      case tail do
        ["," | rest] -> arguments(rest, fields, [ast | args])
        [")" | rest] -> {:ok, Enum.reverse([ast | args]), rest}
        _ -> {:error, :invalid_formula}
      end
    end
  end

  defp infer(%{"kind" => "literal", "value" => value}, _) do
    type =
      cond do
        is_number(value) -> :number
        is_boolean(value) -> :boolean
        true -> :text
      end

    {:ok, type, false}
  end

  defp infer(%{"kind" => "number"}, _), do: {:ok, :number, false}

  defp infer(%{"kind" => "field", "id" => id}, fields) do
    case fields[id] do
      nil -> {:error, :unknown_formula_field}
      field -> {:ok, type(field), field.config["volatile"] == true}
    end
  end

  defp infer(%{"kind" => "unary", "op" => op, "arg" => arg}, fields) do
    with {:ok, type, volatile} <- infer(arg, fields),
         true <- type == if(op == "!", do: :boolean, else: :number),
         do: {:ok, type, volatile},
         else: (_ -> {:error, :formula_type})
  end

  defp infer(%{"kind" => "binary", "op" => op, "left" => left, "right" => right}, fields) do
    with {:ok, lt, lv} <- infer(left, fields),
         {:ok, rt, rv} <- infer(right, fields),
         {:ok, type} <- binary_type(op, lt, rt),
         do: {:ok, type, lv or rv}
  end

  defp infer(%{"kind" => "call", "name" => name, "args" => args}, fields) do
    with {:ok, types} <- infer_args(args, fields),
         {:ok, type} <- call_type(name, Enum.map(types, &elem(&1, 0))),
         do: {:ok, type, name in ["TODAY", "NOW"] or Enum.any?(types, &elem(&1, 1))}
  end

  defp infer(_, _), do: {:error, :invalid_formula}

  defp infer_args(args, fields) do
    Enum.reduce_while(args, {:ok, []}, fn arg, {:ok, acc} ->
      case infer(arg, fields) do
        {:ok, type, volatile} -> {:cont, {:ok, [{type, volatile} | acc]}}
        error -> {:halt, error}
      end
    end)
    |> reverse_values()
  end

  defp binary_type(op, :number, :number) when op in ["+", "-", "*", "/", "%"], do: {:ok, :number}
  defp binary_type(op, :datetime, :number) when op in ["+", "-"], do: {:ok, :datetime}
  defp binary_type(op, :boolean, :boolean) when op in ["&&", "||"], do: {:ok, :boolean}

  defp binary_type(op, type, type) when op in ["=", "==", "!=", "<>", ">", ">=", "<", "<="],
    do: {:ok, :boolean}

  defp binary_type("&", _, _), do: {:ok, :text}
  defp binary_type(_, _, _), do: {:error, :formula_type}

  defp call_type(name, types) when name in ~w(SUM AVERAGE MIN MAX),
    do:
      if(types != [] and Enum.all?(types, &(&1 == :number)),
        do: {:ok, :number},
        else: {:error, :formula_type}
      )

  defp call_type(name, [:number]) when name in ~w(ABS INT), do: {:ok, :number}
  defp call_type("ROUND", types) when types in [[:number], [:number, :number]], do: {:ok, :number}
  defp call_type("MOD", [:number, :number]), do: {:ok, :number}
  defp call_type("IF", [:boolean, type, type]), do: {:ok, type}

  defp call_type(name, types) when name in ~w(AND OR),
    do:
      if(types != [] and Enum.all?(types, &(&1 == :boolean)),
        do: {:ok, :boolean},
        else: {:error, :formula_type}
      )

  defp call_type("NOT", [:boolean]), do: {:ok, :boolean}
  defp call_type("ISBLANK", [_]), do: {:ok, :boolean}

  defp call_type("CONCATENATE", types),
    do: if(types != [], do: {:ok, :text}, else: {:error, :formula_type})

  defp call_type("LEN", [:text]), do: {:ok, :number}
  defp call_type(name, [:text, :number]) when name in ~w(LEFT RIGHT), do: {:ok, :text}
  defp call_type("MID", [:text, :number, :number]), do: {:ok, :text}
  defp call_type(name, [:text]) when name in ~w(UPPER LOWER TRIM), do: {:ok, :text}
  defp call_type("VALUE", [:text]), do: {:ok, :number}
  defp call_type(name, []) when name in ~w(TODAY NOW), do: {:ok, :datetime}
  defp call_type("DATEDIF", [:datetime, :datetime, :text]), do: {:ok, :number}
  defp call_type(_, _), do: {:error, :formula_type}

  defp sql_field(%{type: :formula} = field, fields, params) do
    with {:ok, expr, params} <- sql(field.config["ast"], fields, params) do
      expr = if field.config["result_type"] == "text", do: "NULLIF((#{expr}), '')", else: expr
      {:ok, expr, params}
    end
  end

  defp sql_field(field, _fields, params) do
    case to_string(field.type) do
      "created_at" ->
        {:ok, timestamp_sql("r.created_at"), params}

      "updated_at" ->
        {:ok, timestamp_sql("r.updated_at"), params}

      "created_by" ->
        {:ok, "r.created_by", params}

      "updated_by" ->
        {:ok, "r.updated_by", params}

      _ ->
        {param, params} = bind(params, field.id)

        sql =
          case type(field) do
            :number -> "(r.data ->> #{param}::text)::numeric"
            :boolean -> "(r.data ->> #{param}::text)::boolean"
            :array -> "r.data -> #{param}::text"
            _ -> "r.data ->> #{param}::text"
          end

        {:ok, "(" <> sql <> ")", params}
    end
  end

  defp sql(%{"kind" => "literal", "value" => value}, _fields, params) do
    {param, params} = bind(params, if(is_number(value), do: to_string(value), else: value))

    cast =
      cond do
        is_number(value) -> "text::numeric"
        is_boolean(value) -> "boolean"
        true -> "text"
      end

    {:ok, param <> "::" <> cast, params}
  end

  defp sql(%{"kind" => "number", "value" => text}, _fields, params) do
    {param, params} = bind(params, text)

    {:ok,
     "(CASE WHEN pg_input_is_valid(#{param}::text, 'numeric') THEN #{param}::text END)::numeric",
     params}
  end

  defp sql(%{"kind" => "field", "id" => id}, plan, params) do
    case Map.fetch(plan.expressions, id) do
      :error -> {:error, :unknown_formula_field}
      {:ok, sql} -> {:ok, sql, params}
    end
  end

  defp sql(%{"kind" => "unary", "op" => op, "arg" => arg}, fields, params) do
    with {:ok, value, params} <- sql(arg, fields, params),
         do: {:ok, "(" <> if(op == "!", do: "NOT ", else: op) <> value <> ")", params}
  end

  defp sql(
         %{"kind" => "binary", "op" => op, "left" => left, "right" => right},
         fields,
         params
       ) do
    with {:ok, l, params} <- sql(left, fields, params),
         {:ok, r, params} <- sql(right, fields, params),
         {:ok, lt, _} <- infer(left, fields.definitions) do
      result =
        cond do
          op == "/" ->
            "#{l} / NULLIF(#{r}, 0)"

          op == "%" ->
            "mod(#{l}, NULLIF(#{r}, 0))"

          op == "&" ->
            "COALESCE(#{l}::text, '') || COALESCE(#{r}::text, '')"

          op in ["+", "-"] and lt == :datetime ->
            timestamp_sql("#{l}::timestamptz #{op} (#{r} * INTERVAL '1 day')")

          true ->
            "#{l} #{Map.get(%{"&&" => "AND", "||" => "OR", "==" => "=", "!=" => "<>"}, op, op)} #{r}"
        end

      {:ok, "(" <> result <> ")", params}
    end
  end

  defp sql(%{"kind" => "call", "name" => name, "args" => args}, fields, params) do
    with {:ok, values, params} <- sql_args(args, fields, params),
         do: call_sql(name, values, params)
  end

  defp sql_args(args, fields, params) do
    Enum.reduce_while(args, {:ok, [], params}, fn arg, {:ok, acc, params} ->
      case sql(arg, fields, params) do
        {:ok, sql, params} -> {:cont, {:ok, [sql | acc], params}}
        error -> {:halt, error}
      end
    end)
    |> reverse_values()
  end

  defp call_sql(name, values, params), do: {:ok, "(" <> template(name, values) <> ")", params}

  defp template(name, values) when name in ~w(SUM AVERAGE MIN MAX ROUND ABS INT MOD) do
    case {name, values} do
      {"SUM", _} ->
        Enum.map_join(values, " + ", &"COALESCE(#{&1},0)")

      {"AVERAGE", _} ->
        "(SELECT avg(v) FROM (VALUES " <>
          Enum.map_join(values, ",", &"(#{&1})") <> ") AS formula_values(v))"

      {"MIN", _} ->
        "LEAST(" <> Enum.join(values, ",") <> ")"

      {"MAX", _} ->
        "GREATEST(" <> Enum.join(values, ",") <> ")"

      {"ROUND", [v]} ->
        "round(#{v})"

      {"ROUND", [v, digits]} ->
        "round(#{v},#{digits}::integer)"

      {"ABS", [v]} ->
        "abs(#{v})"

      {"INT", [v]} ->
        "floor(#{v})"

      {"MOD", [a, b]} ->
        "mod(#{a}, NULLIF(#{b},0))"
    end
  end

  defp template(name, values) when name in ~w(IF AND OR NOT ISBLANK) do
    case {name, values} do
      {"IF", [test, a, b]} ->
        "CASE WHEN #{test} THEN #{a} ELSE #{b} END"

      {"AND", _} ->
        Enum.join(values, " AND ")

      {"OR", _} ->
        Enum.join(values, " OR ")

      {"NOT", [v]} ->
        "NOT #{v}"

      {"ISBLANK", [v]} ->
        "#{v} IS NULL"
    end
  end

  defp template(name, values)
       when name in ~w(CONCATENATE LEN LEFT RIGHT MID UPPER LOWER TRIM VALUE) do
    case {name, values} do
      {"CONCATENATE", _} ->
        "concat(" <> Enum.join(values, ",") <> ")"

      {"LEN", [v]} ->
        "char_length(#{v})"

      {"LEFT", [v, n]} ->
        "left(#{v},greatest(#{n}::integer,0))"

      {"RIGHT", [v, n]} ->
        "right(#{v},greatest(#{n}::integer,0))"

      {"MID", [v, start, n]} ->
        "substring(#{v} FROM greatest(#{start}::integer,1) FOR greatest(#{n}::integer,0))"

      {"UPPER", [v]} ->
        "upper(#{v})"

      {"LOWER", [v]} ->
        "lower(#{v})"

      {"TRIM", [v]} ->
        "btrim(#{v})"

      {"VALUE", [v]} ->
        "(CASE WHEN pg_input_is_valid(#{v}, 'numeric') THEN #{v} END)::numeric"
    end
  end

  defp template(name, values) when name in ~w(NOW TODAY DATEDIF) do
    case {name, values} do
      {"NOW", []} ->
        timestamp_sql("CURRENT_TIMESTAMP")

      {"TODAY", []} ->
        timestamp_sql("date_trunc('day', CURRENT_TIMESTAMP, current_setting('TimeZone'))")

      {"DATEDIF", [a, b, unit]} ->
        "CASE lower(#{unit}) WHEN 'd' THEN extract(epoch FROM (#{b}::timestamptz - #{a}::timestamptz))/86400 WHEN 'm' THEN extract(year FROM age(#{b}::timestamptz,#{a}::timestamptz))*12+extract(month FROM age(#{b}::timestamptz,#{a}::timestamptz)) WHEN 'y' THEN extract(year FROM age(#{b}::timestamptz,#{a}::timestamptz)) END"
    end
  end

  defp reverse_values({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_values({:ok, values, params}), do: {:ok, Enum.reverse(values), params}
  defp reverse_values(error), do: error

  defp timestamp_sql(sql),
    do: "to_char((#{sql}) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')"

  defp referenced?(%{"kind" => "field", "id" => id}, id), do: true
  defp referenced?(ast, id) when is_map(ast), do: Enum.any?(Map.values(ast), &referenced?(&1, id))
  defp referenced?(list, id) when is_list(list), do: Enum.any?(list, &referenced?(&1, id))
  defp referenced?(_, _), do: false
end
