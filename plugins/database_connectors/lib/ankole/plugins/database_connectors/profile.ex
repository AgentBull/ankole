defmodule Ankole.Plugins.DatabaseConnectors.Profile do
  @moduledoc """
  Classifies sensitive columns and summarizes sampled values.

  A column is sensitive when its name or type suggests personal or secret
  data, or when the connection's `sample_exclusions` names it. Ankole never
  reads sample values from a sensitive column, so its cached profile and its
  probes carry counts only.
  """

  @sensitive_name ~r/pass(word)?|passwd|pwd|secret|token|api_?key|private_?key|credential|salt|hash|ssn|social_?security|national_?id|id_?card|id_?number|passport|driver_?licen[cs]e|tax_?id|phone|mobile|cell_?phone|telephone|e_?mail|address|street|zip_?code|postal|birth|dob|salary|wage|income|iban|swift|bank|card_?(no|num)|credit_?card|cvv|account_?(no|num)|ip_?addr|latitude|longitude|geo_?loc|身份证|证件|护照|手机|电话|邮箱|地址|住址|生日|出生|密码|口令|银行|卡号|工资|薪/iu
  @sensitive_type ~r/bytea|blob|binary|bit\b|geometry|geography|point|polygon|inet|cidr|macaddr|tsvector/i
  @sample_values 10
  @value_chars 80

  @doc "Marks each column's `sensitive` flag from the heuristics and the connection's exclusions."
  def mark(%{"columns" => columns} = table, exclusions) do
    %{
      table
      | "columns" =>
          Enum.map(columns, fn column ->
            Map.put(column, "sensitive", sensitive?(table, column, exclusions))
          end)
    }
  end

  def sensitive?(table, column, exclusions) do
    name = column["name"] || ""

    Regex.match?(@sensitive_name, name) or Regex.match?(@sensitive_type, column["type"] || "") or
      excluded?(table, name, exclusions)
  end

  @doc """
  Reads `sample_exclusions` entries: `column`, `table.column`, or
  `schema.table.column`, matched without regard to case; `*` matches any name.
  """
  def exclusions(metadata) do
    case metadata["sample_exclusions"] do
      list when is_list(list) -> list
      text when is_binary(text) -> String.split(text, [",", "\n"])
      _ -> []
    end
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.split(&1, "."))
  end

  defp excluded?(table, name, exclusions) do
    target = Enum.map([table["schema"] || "", table["name"] || "", name], &String.downcase/1)

    Enum.any?(exclusions, fn pattern ->
      target
      |> Enum.take(-length(pattern))
      |> Enum.zip(pattern)
      |> Enum.all?(fn {part, expected} -> expected in ["*", part] end) and
        length(pattern) <= 3
    end)
  end

  @doc "Drops the value-bearing fields from a sensitive column's profile."
  def masked(profile) when is_map(profile), do: Map.drop(profile, ["sample_values", "min", "max"])
  def masked(profile), do: profile

  @doc "Summarizes the sampled rows of the profiled columns; `sampled` lists their names in order."
  def summarize(table, sampled, rows, fetched_at) do
    index = sampled |> Enum.with_index() |> Map.new()
    total = length(rows)

    columns =
      Enum.map(table["columns"], fn column ->
        case Map.fetch(index, column["name"]) do
          {:ok, i} when total > 0 ->
            Map.put(column, "profile", column_profile(rows, i, total, fetched_at))

          _ ->
            column
        end
      end)

    %{table | "columns" => columns}
  end

  defp column_profile(rows, index, total, fetched_at) do
    values = Enum.map(rows, &Enum.at(&1, index))
    present = Enum.reject(values, &is_nil/1)
    frequencies = Enum.frequencies(present)
    distinct = map_size(frequencies)
    {min, max} = bounds(present)

    %{
      "sampled_rows" => total,
      "null_fraction" => Float.round((total - length(present)) / total, 4),
      "distinct_in_sample" => distinct,
      "sample_values" =>
        frequencies
        |> Enum.sort_by(fn {value, count} -> {-count, inspect(value)} end)
        |> Enum.take(@sample_values)
        |> Enum.map(fn {value, _count} -> clip(value) end),
      "low_cardinality" => distinct > 0 and distinct <= 20 and distinct < total,
      "min" => clip(min),
      "max" => clip(max),
      "fetched_at" => fetched_at
    }
  end

  # Drivers return decimals and ClickHouse numbers as strings; numeric text compares by value.
  defp bounds([]), do: {nil, nil}

  defp bounds(values) do
    numbers = Enum.map(values, &number/1)

    cond do
      Enum.all?(numbers) ->
        pairs = Enum.zip(numbers, values)

        {pairs |> Enum.min_by(&elem(&1, 0), Decimal) |> elem(1),
         pairs |> Enum.max_by(&elem(&1, 0), Decimal) |> elem(1)}

      Enum.all?(values, &is_binary/1) ->
        Enum.min_max(values)

      true ->
        {nil, nil}
    end
  end

  defp number(value) when is_integer(value), do: Decimal.new(value)
  defp number(value) when is_float(value), do: Decimal.from_float(value)

  defp number(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp number(_), do: nil

  defp clip(value) when is_binary(value), do: String.slice(value, 0, @value_chars)
  defp clip(value) when is_map(value) or is_list(value), do: nil
  defp clip(value), do: value
end
