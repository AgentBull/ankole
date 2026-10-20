defmodule Ankole.Attrs do
  @moduledoc """
  Shared normalization for external attribute maps.

  Console controllers and subsystem writers accept caller-supplied attribute
  maps with atom or string keys. This module holds the transforms that are
  identical across subsystems, so each subsystem keeps only its own domain
  rules.
  """

  @doc """
  Reads an atom key or its string form. The atom key takes precedence.
  """
  def get(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, to_string(key), default))

  @doc """
  Trims a string and returns `nil` for blank strings or other values.
  """
  @spec optional_text(term()) :: String.t() | nil
  def optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  def optional_text(_value), do: nil

  @doc """
  Reads an integer or a complete decimal integer string.
  """
  @spec integer_value(term()) :: integer() | nil
  def integer_value(value) when is_integer(value), do: value

  def integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _value -> nil
    end
  end

  def integer_value(_value), do: nil

  @doc """
  Puts the value unless it is `nil`.
  """
  @spec maybe_put(map(), term(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Puts the value unless it is `nil` or the empty string.
  """
  @spec put_present(map(), term(), term()) :: map()
  def put_present(map, _key, nil), do: map
  def put_present(map, _key, ""), do: map
  def put_present(map, key, value), do: Map.put(map, key, value)

  @doc """
  Collects `{:ok, value}` results in order and halts on the first error.
  """
  @spec collect_results(Enumerable.t()) :: {:ok, [term()]} | {:error, term()}
  def collect_results(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Converts top-level atom keys to strings and keeps values unchanged.
  """
  @spec normalize_external_attrs(map()) :: map()
  def normalize_external_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  def datetime_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  def datetime_iso8601(_value), do: nil

  def digest(parts) do
    parts
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  def normalize_provider_lifecycle_kind(nil), do: nil

  def normalize_provider_lifecycle_kind(kind) when is_atom(kind) do
    kind
    |> Atom.to_string()
    |> normalize_provider_lifecycle_kind()
  end

  def normalize_provider_lifecycle_kind(kind) when is_binary(kind), do: optional_text(kind)

  def normalize_provider_lifecycle_kind(_kind), do: nil

  def parse_datetime(nil), do: nil

  def parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  def parse_datetime(%DateTime{} = value), do: value

  def parse_datetime(_value), do: nil

  def reply_delivery_retry_after_seconds(%{"retry_after_seconds" => seconds})
      when is_integer(seconds) and seconds > 0,
      do: seconds

  def reply_delivery_retry_after_seconds(%{retry_after_seconds: seconds})
      when is_integer(seconds) and seconds > 0,
      do: seconds

  def reply_delivery_retry_after_seconds(_detail), do: 0

  def structured_mention?(mention, agent_uid) when is_map(mention) do
    structured? =
      truthy?(Map.get(mention, "structured")) ||
        Map.get(mention, "kind") in ["agent", "bot"]

    mentioned_agent = Ankole.Attrs.optional_text(Map.get(mention, "agent_uid"))

    structured? and targets_current_agent?(mention) and
      (is_nil(mentioned_agent) or Ankole.PrincipalKey.canonicalize(mentioned_agent) == agent_uid)
  end

  def structured_mention?(_mention, _agent_uid), do: false

  def truthy?(value) when value in [true, "true", 1, "1"], do: true

  def truthy?(_value), do: false

  def validate_module_callback(module, function, arity) do
    case function_exported?(module, function, arity) do
      true -> :ok
      false -> {:error, {:missing_adapter_callback, module, function, arity}}
    end
  end

  defp targets_current_agent?(mention) do
    case Map.get(mention, "targets_current_agent") do
      false -> false
      "false" -> false
      _value -> true
    end
  end
end
