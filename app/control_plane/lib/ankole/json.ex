defmodule Ankole.JSON do
  @moduledoc """
  Torque-backed JSON adapter for Phoenix and Plug integration points.

  Phoenix expects `encode_to_iodata!/1` from its configured JSON library, while
  Torque exposes `encode_to_iodata/1`. This module keeps that compatibility
  surface local and delegates actual JSON work to Torque.
  """

  @doc "Encodes an Elixir term into a JSON binary."
  @spec encode(term()) :: {:ok, binary()} | {:error, term()}
  defdelegate encode(term), to: Torque

  @doc "Encodes an Elixir term into a JSON binary, raising on failure."
  @spec encode!(term()) :: binary()
  defdelegate encode!(term), to: Torque

  @doc "Encodes an Elixir term into iodata, raising on failure."
  @spec encode_to_iodata!(term()) :: iodata()
  def encode_to_iodata!(term), do: Torque.encode_to_iodata(term)

  @doc """
  Deeply converts a term into JSON-plain data: map keys become strings and
  calendar structs become ISO 8601 strings.

  Torque encodes only plain terms, so response payloads that carry
  `DateTime`, `NaiveDateTime`, `Date`, or `Time` values must pass through
  this transform before encoding. Any other struct stays unchanged and
  still fails at encode time, because a non-calendar struct in a payload
  is a bug to surface, not data to mangle.
  """
  @spec plain(term()) :: term()
  def plain(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def plain(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def plain(%Date{} = value), do: Date.to_iso8601(value)
  def plain(%Time{} = value), do: Time.to_iso8601(value)
  def plain(%_struct{} = value), do: value

  def plain(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {plain_key(key), plain(value)} end)
  end

  def plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  def plain(value), do: value

  defp plain_key(key) when is_binary(key), do: key
  defp plain_key(key) when is_atom(key), do: Atom.to_string(key)
  defp plain_key(key) when is_integer(key), do: Integer.to_string(key)

  @doc "Decodes JSON iodata into Elixir terms."
  @spec decode(iodata()) :: {:ok, term()} | {:error, term()}
  def decode(data), do: data |> normalize_iodata() |> Torque.decode()

  @doc "Decodes JSON iodata into Elixir terms, raising on failure."
  @spec decode!(iodata()) :: term()
  def decode!(data), do: data |> normalize_iodata() |> Torque.decode!()

  defp normalize_iodata(data) when is_binary(data), do: data
  defp normalize_iodata(data) when is_list(data), do: IO.iodata_to_binary(data)
end
