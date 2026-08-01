defmodule Ankole.Kernel.RuntimeFabric do
  @moduledoc """
  Elixir facade for RuntimeFabric envelope transport.

  Envelopes are `Ankole.RuntimeFabric.V1.Envelope` structs generated from
  `envelope.proto` by `Ankole.Kernel.RuntimeFabric.Proto`; this facade encodes
  them and drives the Rust-owned ZeroMQ ROUTER socket. The native kernel
  validates protocol invariants on every send and receive, so both hosts see
  the same semantic errors. Actor and RPC semantics live above this layer in
  the control plane.
  """

  alias Ankole.Kernel
  alias Ankole.RuntimeFabric.V1.Envelope

  @protocol_version 4

  @type router :: reference()

  @doc """
  Returns the only RuntimeFabric protocol version this runtime admits.

  A wire-incompatible worker or control plane must fail before worker
  scheduling; RuntimeFabric does not negotiate mixed protocol versions.
  """
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

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
      {:error, reason} -> {:error, normalize_transport_error(reason)}
      other -> {:error, other}
    end
  end

  @doc """
  Sends one raw worker-file multipart frame set to a worker route.

  File transfer frames are the RuntimeFabric byte lane. They intentionally do
  not pass through the protobuf envelope codec used by actor and RPC traffic.
  """
  @spec router_send_file_frame(router(), String.t(), [binary()]) ::
          {:ok, :sent_or_queued} | {:error, atom() | String.t()}
  def router_send_file_frame(router, transport_route, frames)
      when is_binary(transport_route) and is_list(frames) do
    case Kernel.runtime_fabric_router_send_file_frame(router, transport_route, frames) do
      "sent_or_queued" -> {:ok, :sent_or_queued}
      {:error, reason} -> {:error, normalize_transport_error(reason)}
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
      {:error, reason} -> {:error, normalize_transport_error(reason)}
      other -> {:error, other}
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_transport_error("unknown_route"), do: :unknown_route
  defp normalize_transport_error("backpressure"), do: :backpressure
  defp normalize_transport_error("timeout"), do: :timeout
  defp normalize_transport_error("socket_closed"), do: :socket_closed
  defp normalize_transport_error(reason), do: reason
end
