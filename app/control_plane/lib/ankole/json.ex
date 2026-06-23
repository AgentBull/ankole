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

  @doc "Decodes JSON iodata into Elixir terms."
  @spec decode(iodata()) :: {:ok, term()} | {:error, term()}
  def decode(data), do: data |> normalize_iodata() |> Torque.decode()

  @doc "Decodes JSON iodata into Elixir terms, raising on failure."
  @spec decode!(iodata()) :: term()
  def decode!(data), do: data |> normalize_iodata() |> Torque.decode!()

  defp normalize_iodata(data) when is_binary(data), do: data
  defp normalize_iodata(data) when is_list(data), do: IO.iodata_to_binary(data)
end
