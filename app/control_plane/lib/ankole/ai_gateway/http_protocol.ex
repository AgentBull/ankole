defmodule Ankole.AIGateway.HttpProtocol do
  @moduledoc """
  Validates and converts AIGateway HTTP protocol settings for Finch.
  """

  @valid_protocols ~w(http1 http2)

  @doc "Returns whether a protocol value is accepted by AIGateway."
  @spec valid?(term()) :: boolean()
  def valid?(protocol), do: protocol in @valid_protocols

  @doc "Validates an optional provider-row HTTP protocol override."
  @spec validate_optional(term()) :: :ok | {:error, :invalid_http_protocol}
  def validate_optional(nil), do: :ok
  def validate_optional(protocol) when protocol in @valid_protocols, do: :ok
  def validate_optional(_protocol), do: {:error, :invalid_http_protocol}

  @doc """
  Returns the single Finch protocol list used for a provider request.
  """
  # Keep this as a single Finch protocol, not an adaptive `[:http1, :http2]`
  # pool. Mixed protocol pools can fail large-body HTTP/2 requests after
  # negotiating an HTTP/1 connection; see https://github.com/sneako/finch/issues/265.
  @spec finch_protocols(term()) :: {:ok, [:http1] | [:http2]} | {:error, :invalid_http_protocol}
  def finch_protocols("http1"), do: {:ok, [:http1]}
  def finch_protocols("http2"), do: {:ok, [:http2]}
  def finch_protocols(:http1), do: {:ok, [:http1]}
  def finch_protocols(:http2), do: {:ok, [:http2]}
  def finch_protocols(_protocol), do: {:error, :invalid_http_protocol}
end
