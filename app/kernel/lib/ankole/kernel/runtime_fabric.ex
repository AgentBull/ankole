defmodule Ankole.Kernel.RuntimeFabric do
  @moduledoc """
  Elixir facade for RuntimeFabric envelope transport.

  Envelopes are `Ankole.RuntimeFabric.V1.Envelope` structs generated from
  `envelope.proto` by `Ankole.Kernel.RuntimeFabric.Proto`. This facade seals
  and validates them through the kernel, which stays the single semantic
  checker for both hosts, and drives the Rust-owned ZeroMQ ROUTER socket that
  the dual-stack migration keeps for Workers on the `tcp://` transport. Actor
  and RPC semantics live above this layer in the control plane.
  """

  alias Ankole.Kernel
  alias Ankole.RuntimeFabric.V1.Envelope

  @type router :: reference()

  @doc """
  Encodes a RuntimeFabric envelope struct as protobuf bytes.
  """
  @spec encode_envelope(Envelope.t()) :: binary()
  def encode_envelope(%Envelope{} = envelope) do
    {iodata, _size} = Envelope.encode!(envelope)
    IO.iodata_to_binary(iodata)
  end

  @doc """
  Decodes RuntimeFabric protobuf bytes into an envelope struct.
  """
  @spec decode_envelope(binary()) :: {:ok, Envelope.t()} | {:error, term()}
  def decode_envelope(bytes) when is_binary(bytes), do: Envelope.decode(bytes)

  @doc """
  Encodes and seals one envelope for the wire.

  Callers build envelopes with a body and correlation only; the kernel writes
  the header and rejects a body that breaks the protocol.
  """
  @spec seal_and_encode(Envelope.t()) :: {:ok, binary()} | {:error, String.t()}
  def seal_and_encode(%Envelope{} = envelope) do
    case Kernel.runtime_fabric_seal_envelope(encode_envelope(envelope)) do
      {:error, reason} -> {:error, reason}
      bytes when is_binary(bytes) -> {:ok, bytes}
    end
  end

  @doc """
  Validates inbound bytes with the kernel and decodes them.
  """
  @spec decode_and_validate(binary()) :: {:ok, Envelope.t()} | {:error, term()}
  def decode_and_validate(bytes) when is_binary(bytes) do
    case Kernel.runtime_fabric_validate_envelope(bytes) do
      true -> decode_envelope(bytes)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Starts a Rust-owned ZeroMQ ROUTER socket.
  """
  @spec router_start(String.t(), pid(), keyword()) :: {:ok, router()} | {:error, String.t()}
  def router_start(endpoint, owner_pid, opts \\ [])
      when is_binary(endpoint) and is_pid(owner_pid) and is_list(opts) do
    opts =
      opts
      |> Map.new()
      |> stringify_keys()
      |> Torque.encode!()

    case Kernel.runtime_fabric_router_start(endpoint, owner_pid, opts) do
      {:error, reason} -> {:error, reason}
      router -> {:ok, router}
    end
  end

  @doc """
  Returns the actual ROUTER endpoint after ZeroMQ expands wildcard ports.
  """
  @spec router_endpoint(router()) :: String.t() | {:error, String.t()}
  def router_endpoint(router), do: Kernel.runtime_fabric_router_endpoint(router)

  @doc """
  Sends one envelope with mandatory ROUTER routing enabled.

  The native router validates the encoded envelope before it reaches the
  socket thread.
  """
  @spec router_send_mandatory(router(), String.t(), Envelope.t()) ::
          {:ok, :sent_or_queued} | {:error, atom() | String.t()}
  def router_send_mandatory(router, transport_route, %Envelope{} = envelope)
      when is_binary(transport_route) do
    envelope_bytes = encode_envelope(envelope)

    case Kernel.runtime_fabric_router_send_mandatory(router, transport_route, envelope_bytes) do
      "sent_or_queued" -> {:ok, :sent_or_queued}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @doc """
  Stops the Rust-owned ROUTER socket.
  """
  @spec router_stop(router()) :: :ok | {:error, atom() | String.t()}
  def router_stop(router) do
    case Kernel.runtime_fabric_router_stop(router) do
      true -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
