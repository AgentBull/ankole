defmodule Ankole.Kernel.RuntimeFabric do
  @moduledoc """
  The control-plane codec boundary for RuntimeFabric envelopes.

  Protox generates the codec from `envelope.proto`. Each host writes and checks
  the declared protocol version. Domain consumers check execution references.
  """

  alias Ankole.RuntimeFabric.V1.Envelope

  @protocol_version Ankole.RuntimeFabric.V1.ProtocolVersion.encode(:PROTOCOL_VERSION_CURRENT)

  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @spec encode_envelope(Envelope.t()) :: binary()
  def encode_envelope(%Envelope{} = envelope) do
    {iodata, _size} = Envelope.encode!(envelope)
    IO.iodata_to_binary(iodata)
  end

  @spec seal_and_encode(Envelope.t()) :: binary()
  def seal_and_encode(%Envelope{} = envelope),
    do: encode_envelope(%{envelope | protocol_version: @protocol_version})

  @spec decode_and_validate(binary()) :: {:ok, Envelope.t()} | {:error, term()}
  def decode_and_validate(bytes) when is_binary(bytes) do
    case Envelope.decode(bytes) do
      {:ok, %Envelope{protocol_version: @protocol_version} = envelope} ->
        {:ok, envelope}

      {:ok, %Envelope{protocol_version: version}} ->
        {:error, {:unsupported_protocol_version, version}}

      {:error, _reason} = error ->
        error
    end
  end
end
