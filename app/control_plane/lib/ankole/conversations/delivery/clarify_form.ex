defmodule Ankole.Conversations.Delivery.ClarifyForm do
  @moduledoc """
  Owns the field contract of a structured `clarify` form.

  The `clarify` tool calls `definition/1` before it records a question, so an
  invalid definition returns a precise message to the model. Every answer
  surface calls `answer/2` before it resolves the interaction, so an invalid
  submission returns per-field error codes and leaves the question pending.
  Error codes never echo submitted values.
  """

  alias Ankole.I18n

  @types ~w(text number date select multi_select boolean)
  @max_fields 5
  @id_pattern ~r/\A[a-z][a-z0-9_]{0,39}\z/
  @max_text_length 1_000
  @default_text_length 200

  @type field :: %{String.t() => term()}
  @type errors :: %{String.t() => String.t()}

  @doc """
  Normalizes a model-supplied field list.

  Returns `{:ok, []}` when the clarify has no form. At least one field must be
  required. A normalized list normalizes to itself, so a stored presentation
  can pass its fields through this function again.
  """
  @spec definition(term()) :: {:ok, [field()]} | {:error, String.t()}
  def definition(nil), do: {:ok, []}

  def definition(fields) when is_list(fields) and length(fields) in 1..@max_fields do
    with {:ok, fields} <-
           fields
           |> Enum.with_index()
           |> Enum.map(fn {field, index} -> field(field, "fields[#{index}]") end)
           |> Ankole.Attrs.collect_results(),
         :ok <- unique(Enum.map(fields, & &1["id"]), "fields", "id"),
         :ok <- any_required(fields) do
      {:ok, fields}
    end
  end

  def definition(_fields), do: {:error, "fields must list 1 to #{@max_fields} fields"}

  @doc """
  Validates submitted values against normalized fields.

  The result holds typed values keyed by field ID. Select fields hold option
  values; date fields hold ISO 8601 calendar dates. Optional fields without a
  value are omitted, and unknown keys are ignored.
  """
  @spec answer([field()], term()) :: {:ok, map()} | {:error, errors()}
  def answer(fields, values) when is_list(fields) do
    values = if is_map(values), do: values, else: %{}

    {typed, errors} =
      Enum.reduce(fields, {%{}, %{}}, fn %{"id" => id} = field, {typed, errors} ->
        case value(field, Map.get(values, id)) do
          {:ok, value} ->
            {Map.put(typed, id, value), errors}

          :empty ->
            if field["required"],
              do: {typed, Map.put(errors, id, "required")},
              else: {typed, errors}

          {:error, code} ->
            {typed, Map.put(errors, id, code)}
        end
      end)

    if errors == %{}, do: {:ok, typed}, else: {:error, errors}
  end

  @doc "Builds the readable one-line summary that the room shows for an answer."
  @spec summary([field()], map()) :: String.t()
  def summary(fields, typed) when is_list(fields) and is_map(typed) do
    fields
    |> Enum.filter(&Map.has_key?(typed, &1["id"]))
    |> Enum.map_join(" · ", fn field ->
      I18n.t("conversations.delivery.clarify.summary_field", %{
        "label" => field["label"],
        "value" => display(field, Map.fetch!(typed, field["id"]))
      })
    end)
  end

  @doc """
  Reads the values that a channel card submits into the JSON values that
  `answer/2` validates.

  Card inputs submit text: numbers and booleans arrive as strings, a date
  picker may append a time zone (`2026-11-20 +0800`), and a multi-select
  arrives as a list or as comma-joined option values. Text that does not
  parse passes through unchanged, so `answer/2` still reports it.
  """
  @spec card_values([field()], term()) :: map()
  def card_values(fields, values) when is_list(fields) and is_map(values) do
    Map.new(fields, fn %{"id" => id} = field -> {id, card_value(field, Map.get(values, id))} end)
  end

  def card_values(_fields, _values), do: %{}

  @doc "Builds the short notice that names each rejected field and its problem."
  @spec error_text([field()], errors()) :: String.t()
  def error_text(fields, errors) when is_list(fields) and is_map(errors) do
    problems =
      fields
      |> Enum.filter(&Map.has_key?(errors, &1["id"]))
      |> Enum.map(fn field ->
        I18n.t("conversations.delivery.clarify.field_error", %{
          "label" => field["label"],
          "problem" => I18n.t("conversations.delivery.clarify.errors.#{errors[field["id"]]}")
        })
      end)

    I18n.t("conversations.delivery.clarify.invalid_answer", %{"problems" => join(problems)})
  end

  defp card_value(%{"type" => "number"}, value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _unparsed -> value
    end
  end

  defp card_value(%{"type" => "boolean"}, "true"), do: true
  defp card_value(%{"type" => "boolean"}, "false"), do: false

  defp card_value(%{"type" => "date"}, value) when is_binary(value) do
    case Regex.run(~r/\A\s*(\d{4}-\d{2}-\d{2})(?:\s|\z)/, value) do
      [_match, date] -> date
      nil -> value
    end
  end

  # shortcut: Teams joins multi-select values with commas, so an option value
  # that contains a comma cannot round-trip through a Teams card; the Pod link
  # still answers it.
  defp card_value(%{"type" => "multi_select"}, value) when is_binary(value),
    do: String.split(value, ",", trim: true)

  defp card_value(_field, value), do: value

  defp field(field, path) when is_map(field) do
    with {:ok, id} <- id(field["id"], path),
         {:ok, label} <- text(field["label"], 80, "#{path}.label"),
         {:ok, help} <- optional_text(field["help"], 200, "#{path}.help"),
         {:ok, type} <- type(field["type"], path),
         {:ok, required} <- boolean(field, "required", true, path),
         {:ok, normalized} <-
           type_params(
             type,
             field,
             %{
               "id" => id,
               "label" => label,
               "type" => type,
               "required" => required
             },
             path
           ),
         normalized = Ankole.Attrs.maybe_put(normalized, "help", help),
         do: default(normalized, field["default"], path)
  end

  defp field(_field, path), do: {:error, "#{path} must be an object"}

  defp id(id, path) when is_binary(id) do
    if Regex.match?(@id_pattern, id),
      do: {:ok, id},
      else:
        {:error,
         "#{path}.id must be snake_case: a lowercase letter, then up to 39 lowercase letters, digits, or underscores"}
  end

  defp id(_id, path), do: {:error, "#{path}.id is required"}

  defp type(type, _path) when type in @types, do: {:ok, type}
  defp type(_type, path), do: {:error, "#{path}.type must be one of #{Enum.join(@types, ", ")}"}

  defp type_params("text", field, base, path) do
    with {:ok, max_length} <-
           integer(field, "max_length", @default_text_length, 1..@max_text_length, path),
         {:ok, multiline} <- boolean(field, "multiline", false, path) do
      {:ok, Map.merge(base, %{"max_length" => max_length, "multiline" => multiline})}
    end
  end

  defp type_params("number", field, base, path) do
    with {:ok, integer} <- boolean(field, "integer", false, path),
         {:ok, min} <- number(field, "min", path),
         {:ok, max} <- number(field, "max", path),
         :ok <- ordered(min, max, path),
         {:ok, unit} <- optional_text(field["unit"], 20, "#{path}.unit") do
      {:ok,
       base
       |> Map.put("integer", integer)
       |> Ankole.Attrs.maybe_put("min", min)
       |> Ankole.Attrs.maybe_put("max", max)
       |> Ankole.Attrs.maybe_put("unit", unit)}
    end
  end

  defp type_params("date", field, base, path) do
    with {:ok, min} <- date_bound(field, "min", path),
         {:ok, max} <- date_bound(field, "max", path),
         :ok <- ordered(min && Date.from_iso8601!(min), max && Date.from_iso8601!(max), path) do
      {:ok, base |> Ankole.Attrs.maybe_put("min", min) |> Ankole.Attrs.maybe_put("max", max)}
    end
  end

  defp type_params("select", field, base, path) do
    with {:ok, options} <- options(field["options"], path),
         do: {:ok, Map.put(base, "options", options)}
  end

  defp type_params("multi_select", field, base, path) do
    with {:ok, options} <- options(field["options"], path),
         count = length(options),
         {:ok, min_items} <- integer(field, "min_items", nil, 0..count, path),
         {:ok, max_items} <- integer(field, "max_items", nil, 1..count, path),
         :ok <- ordered(min_items, max_items, path) do
      {:ok,
       base
       |> Map.put("options", options)
       |> Ankole.Attrs.maybe_put("min_items", min_items)
       |> Ankole.Attrs.maybe_put("max_items", max_items)}
    end
  end

  defp type_params("boolean", _field, base, _path), do: {:ok, base}

  defp default(field, nil, _path), do: {:ok, field}

  defp default(field, default, path) do
    case value(field, default) do
      {:ok, value} ->
        {:ok, Map.put(field, "default", value)}

      _empty_or_invalid ->
        {:error, "#{path}.default is not a valid #{field["type"]} value for this field"}
    end
  end

  defp options(options, path) when is_list(options) and length(options) in 2..10 do
    with {:ok, options} <-
           options
           |> Enum.with_index()
           |> Enum.map(fn
             {%{} = option, index} ->
               option_path = "#{path}.options[#{index}]"

               with {:ok, value} <- text(option["value"], 100, "#{option_path}.value"),
                    {:ok, label} <- text(option["label"], 80, "#{option_path}.label"),
                    do: {:ok, %{"value" => value, "label" => label}}

             {_option, index} ->
               {:error, "#{path}.options[#{index}] must be an object"}
           end)
           |> Ankole.Attrs.collect_results(),
         :ok <- unique(Enum.map(options, & &1["value"]), "#{path}.options", "value") do
      {:ok, options}
    end
  end

  defp options(_options, path), do: {:error, "#{path}.options must list 2 to 10 options"}

  # An all-optional form could be submitted empty, which answers nothing.
  defp any_required(fields) do
    if Enum.any?(fields, & &1["required"]),
      do: :ok,
      else: {:error, "fields must include at least one required field"}
  end

  defp unique(values, path, key) do
    case values -- Enum.uniq(values) do
      [] -> :ok
      [duplicate | _] -> {:error, "#{path} repeats #{key} #{inspect(duplicate)}"}
    end
  end

  defp ordered(min, max, path) do
    if is_nil(min) or is_nil(max) or compare(min, max) != :gt,
      do: :ok,
      else: {:error, "#{path} has a minimum greater than its maximum"}
  end

  defp compare(%Date{} = left, %Date{} = right), do: Date.compare(left, right)
  defp compare(left, right) when left > right, do: :gt
  defp compare(_left, _right), do: :lt

  defp text(value, max, path) do
    case optional_text(value, max, path) do
      {:ok, nil} -> {:error, "#{path} is required"}
      result -> result
    end
  end

  defp optional_text(nil, _max, _path), do: {:ok, nil}

  defp optional_text(value, max, path) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      text ->
        if String.length(text) <= max,
          do: {:ok, text},
          else: {:error, "#{path} exceeds #{max} characters"}
    end
  end

  defp optional_text(_value, _max, path), do: {:error, "#{path} must be a string"}

  defp boolean(field, key, default, path) do
    case Map.get(field, key) do
      nil -> {:ok, default}
      value when is_boolean(value) -> {:ok, value}
      _value -> {:error, "#{path}.#{key} must be a boolean"}
    end
  end

  defp integer(field, key, default, range, path) do
    case Map.get(field, key) do
      nil ->
        {:ok, default}

      value when is_integer(value) ->
        if value in range,
          do: {:ok, value},
          else: {:error, "#{path}.#{key} must be between #{range.first} and #{range.last}"}

      _value ->
        {:error, "#{path}.#{key} must be an integer"}
    end
  end

  defp number(field, key, path) do
    case Map.get(field, key) do
      value when is_number(value) or is_nil(value) -> {:ok, value}
      _value -> {:error, "#{path}.#{key} must be a number"}
    end
  end

  defp date_bound(field, key, path) do
    case Map.get(field, key) do
      nil ->
        {:ok, nil}

      value ->
        case date(value) do
          {:ok, date} -> {:ok, Date.to_iso8601(date)}
          _invalid -> {:error, "#{path}.#{key} must be a YYYY-MM-DD date"}
        end
    end
  end

  defp value(_field, nil), do: :empty

  defp value(%{"type" => "text"} = field, value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        :empty

      text ->
        if String.length(text) <= field["max_length"], do: {:ok, text}, else: {:error, "too_long"}
    end
  end

  defp value(%{"type" => "number"} = field, value) when is_number(value) do
    value = if is_float(value) and value == trunc(value), do: trunc(value), else: value

    cond do
      field["integer"] and not is_integer(value) -> {:error, "not_an_integer"}
      out_of_range?(value, field["min"], field["max"]) -> {:error, "out_of_range"}
      true -> {:ok, value}
    end
  end

  defp value(%{"type" => "date"} = field, value) when is_binary(value) do
    case {String.trim(value), date(value)} do
      {"", _} ->
        :empty

      {_, {:ok, date}} ->
        if out_of_range?(date, date!(field["min"]), date!(field["max"])),
          do: {:error, "out_of_range"},
          else: {:ok, Date.to_iso8601(date)}

      {_, _invalid} ->
        {:error, "invalid_date"}
    end
  end

  defp value(%{"type" => "select"} = field, value) when is_binary(value) do
    cond do
      value == "" -> :empty
      value in option_values(field) -> {:ok, value}
      true -> {:error, "not_an_option"}
    end
  end

  defp value(%{"type" => "multi_select"} = field, values) when is_list(values) do
    allowed = option_values(field)

    cond do
      values == [] ->
        :empty

      not Enum.all?(values, &(&1 in allowed)) or Enum.uniq(values) != values ->
        {:error, "not_an_option"}

      length(values) < (field["min_items"] || 1) ->
        {:error, "too_few"}

      length(values) > (field["max_items"] || length(allowed)) ->
        {:error, "too_many"}

      true ->
        {:ok, Enum.filter(allowed, &(&1 in values))}
    end
  end

  defp value(%{"type" => "boolean"}, value) when is_boolean(value), do: {:ok, value}
  defp value(%{"type" => "number"}, ""), do: :empty
  defp value(_field, _value), do: {:error, "invalid"}

  defp out_of_range?(value, min, max),
    do:
      (not is_nil(min) and compare(min, value) == :gt) or
        (not is_nil(max) and compare(value, max) == :gt)

  defp date(value) when is_binary(value), do: Date.from_iso8601(String.trim(value))
  defp date(_value), do: {:error, :invalid_date}

  defp date!(nil), do: nil
  defp date!(value), do: Date.from_iso8601!(value)

  defp option_values(field), do: Enum.map(field["options"], & &1["value"])

  defp option_label(field, value),
    do: Enum.find_value(field["options"], value, &(&1["value"] == value && &1["label"]))

  defp display(%{"type" => "select"} = field, value), do: option_label(field, value)

  defp display(%{"type" => "multi_select"} = field, values),
    do: values |> Enum.map(&option_label(field, &1)) |> join()

  defp display(%{"type" => "boolean"}, true), do: I18n.t("conversations.delivery.clarify.yes")
  defp display(%{"type" => "boolean"}, false), do: I18n.t("conversations.delivery.clarify.no")

  defp display(%{"type" => "number"} = field, value) do
    number =
      if is_float(value),
        do: :erlang.float_to_binary(value, [:short]),
        else: Integer.to_string(value)

    if field["unit"], do: "#{number} #{field["unit"]}", else: number
  end

  defp display(_field, value), do: String.replace(value, ~r/\s+/u, " ")

  defp join([first | rest]) do
    Enum.reduce(rest, first, fn label, joined ->
      I18n.t("conversations.delivery.clarify.list_join", %{"first" => joined, "next" => label})
    end)
  end
end
