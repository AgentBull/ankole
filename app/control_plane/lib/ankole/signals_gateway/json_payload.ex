defmodule Ankole.SignalsGateway.JsonPayload do
  @moduledoc """
  Strict JSON durability checks for SignalsGateway storage payloads.

  This module is for values that will be written to PostgreSQL JSON/JSONB-like
  fields. It is intentionally stricter than logging sanitization: unsupported
  runtime values should fail before provider ack instead of being stringified
  into durable state.
  """

  import Ecto.Changeset

  @type reason ::
          :unsupported_atom
          | :unsupported_struct
          | :unsupported_runtime_value
          | :non_string_map_key
          | :invalid_json_map
          | :json_encode_failed

  @type normalize_result :: {:ok, term()} | {:error, reason()}

  @doc """
  Normalizes a value into a JSON-serializable Elixir term.
  """
  @spec normalize(term(), keyword()) :: normalize_result()
  def normalize(value, opts \\ [])

  def normalize(%DateTime{} = value, opts) do
    case Keyword.get(opts, :allow_datetime, false) do
      true -> {:ok, DateTime.to_iso8601(value)}
      false -> {:error, :unsupported_struct}
    end
  end

  def normalize(%_struct{}, _opts), do: {:error, :unsupported_struct}

  def normalize(value, _opts)
      when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
      do: {:ok, value}

  # Reject non-nil/boolean atoms instead of stringifying them: an atom round-trips
  # out of JSONB as a string, so silently accepting one would let durable state
  # disagree with what was written. Callers must convert atoms to strings before
  # they reach durable payloads. (true/false/nil matched above are valid JSON.)
  def normalize(value, _opts) when is_atom(value), do: {:error, :unsupported_atom}

  def normalize(value, opts) when is_list(value) do
    value
    |> Enum.map(&normalize(&1, opts))
    |> collect_results()
  end

  def normalize(value, opts) when is_map(value) do
    value
    |> Enum.map(fn {key, map_value} ->
      with {:ok, normalized_key} <- normalize_key(key),
           {:ok, normalized_value} <- normalize(map_value, opts) do
        {:ok, {normalized_key, normalized_value}}
      end
    end)
    |> collect_results()
    |> case do
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      {:error, _reason} = error -> error
    end
  end

  def normalize(_value, _opts), do: {:error, :unsupported_runtime_value}

  @doc """
  Normalizes a durable map field.
  """
  @spec normalize_map(term(), keyword()) :: {:ok, map()} | {:error, reason()}
  def normalize_map(value, opts \\ []) do
    case normalize(value, opts) do
      {:ok, normalized} when is_map(normalized) -> ensure_encodable(normalized)
      {:ok, _other} -> {:error, :invalid_json_map}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Normalizes a durable list field.
  """
  @spec normalize_list(term(), keyword()) :: {:ok, list()} | {:error, reason()}
  def normalize_list(value, opts \\ []) do
    case normalize(value, opts) do
      {:ok, normalized} when is_list(normalized) -> ensure_encodable(normalized)
      {:ok, _other} -> {:error, :invalid_json_map}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Normalizes and validates a map field in an Ecto changeset.
  """
  @spec validate_map(Ecto.Changeset.t(), atom(), keyword()) :: Ecto.Changeset.t()
  def validate_map(changeset, field, opts \\ []) do
    changeset
    |> update_change(field, &normalize_change(&1, opts))
    |> validate_change(field, fn ^field, value ->
      case normalize_map(value, opts) do
        {:ok, _normalized} -> []
        {:error, reason} -> [{field, "must be JSON-serializable object: #{reason}"}]
      end
    end)
  end

  @doc """
  Normalizes and validates a list field in an Ecto changeset.
  """
  @spec validate_list(Ecto.Changeset.t(), atom(), keyword()) :: Ecto.Changeset.t()
  def validate_list(changeset, field, opts \\ []) do
    changeset
    |> update_change(field, &normalize_change(&1, opts))
    |> validate_change(field, fn ^field, value ->
      case normalize_list(value, opts) do
        {:ok, _normalized} -> []
        {:error, reason} -> [{field, "must be JSON-serializable list: #{reason}"}]
      end
    end)
  end

  # In a changeset, normalization is best-effort: rewrite the value when it can
  # be made JSON-safe, but on failure leave the original in place so the paired
  # `validate_change` produces a real validation error (rather than this step
  # swallowing the bad value).
  defp normalize_change(value, opts) do
    case normalize(value, opts) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> value
    end
  end

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: {:error, :non_string_map_key}

  defp ensure_encodable(value) do
    case Ankole.JSON.encode(value) do
      {:ok, _json} -> {:ok, value}
      {:error, _reason} -> {:error, :json_encode_failed}
    end
  end

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end
end
