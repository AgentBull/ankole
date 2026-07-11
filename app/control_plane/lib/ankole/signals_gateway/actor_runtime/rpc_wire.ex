defmodule Ankole.SignalsGateway.ActorRuntime.RPCWire do
  @moduledoc """
  Shared helpers for RuntimeFabric RPC broker payloads.

  Brokers still own domain validation and context calls. This module keeps the
  repeated string/atom-key wire reads and `rpc_error` payload shape consistent.
  """

  @type error_message_style :: :default | :tuple_reason | :inspect_tuple_reason | :tuple_inspect

  @doc """
  Reads a possibly string-keyed or atom-keyed value without creating atoms.
  """
  def value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || atom_key_value(map, key)
  end

  def value(_map, _key), do: nil

  @doc """
  Reads a non-empty binary field, trimming whitespace by default.
  """
  def text(map, key, opts \\ []) do
    case value(map, key) do
      value when is_binary(value) ->
        if Keyword.get(opts, :trim, true) do
          case String.trim(value) do
            "" -> nil
            trimmed -> trimmed
          end
        else
          value
        end

      _value ->
        nil
    end
  end

  @doc """
  Reads a map field, returning the configured default for missing or invalid values.
  """
  def map_value(map, key, default \\ nil) do
    case value(map, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  @doc """
  Recursively converts atom keys to string keys for wire-originated maps.
  """
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) and is_map(value) ->
        {Atom.to_string(key), stringify_keys(value)}

      {key, value} when is_atom(key) ->
        {Atom.to_string(key), value}

      {key, value} when is_map(value) ->
        {key, stringify_keys(value)}

      pair ->
        pair
    end)
  end

  @doc """
  Builds a broker method error payload. The RPCLane wraps this in `rpc_error`.
  """
  def error_payload(request_id, reason, opts) when is_list(opts) do
    fallback_code = Keyword.fetch!(opts, :fallback_code)

    %{
      "request_id" => request_id,
      "code" => error_code(reason, fallback_code, opts),
      "message" => error_message(reason, Keyword.get(opts, :message_style, :default)),
      "details_json" => Keyword.get(opts, :details_json, %{})
    }
  end

  def error_code(reason, fallback_code, opts \\ [])
  def error_code(reason, _fallback_code, _opts) when is_atom(reason), do: Atom.to_string(reason)

  def error_code(%Ecto.Changeset{}, fallback_code, opts) do
    Keyword.get(opts, :changeset_code, fallback_code)
  end

  def error_code({reason, _details}, _fallback_code, _opts) when is_atom(reason),
    do: Atom.to_string(reason)

  def error_code({reason, _key, _details}, _fallback_code, _opts) when is_atom(reason),
    do: Atom.to_string(reason)

  def error_code(_reason, fallback_code, _opts), do: fallback_code

  def error_message(reason, style \\ :default)
  def error_message(%Ecto.Changeset{} = changeset, _style), do: inspect(changeset.errors)
  def error_message(reason, _style) when is_atom(reason), do: Atom.to_string(reason)

  def error_message({reason, _details}, :tuple_reason) when is_atom(reason),
    do: Atom.to_string(reason)

  def error_message({reason, details}, :inspect_tuple_reason) when is_atom(reason),
    do: "#{inspect(reason)}: #{inspect(details)}"

  def error_message({_reason, _details} = reason, :tuple_inspect), do: inspect(reason)
  def error_message({_reason, _key, _details} = reason, :tuple_inspect), do: inspect(reason)

  def error_message({reason, details}, _style) when is_atom(reason),
    do: "#{reason}: #{inspect(details)}"

  def error_message(reason, _style), do: inspect(reason)

  defp atom_key_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end
end
