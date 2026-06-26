defmodule Ankole.Kernel.RuntimeFabric do
  @moduledoc """
  Elixir facade for RuntimeFabric envelope encoding and transport.

  RuntimeFabric owns protobuf serialization plus the ZeroMQ ROUTER socket. Actor
  and RPC semantics live above this layer in the control plane.
  """

  alias Ankole.Kernel

  @type envelope :: map()
  @type router :: reference()

  @doc """
  Encodes a RuntimeFabric envelope map as protobuf bytes.
  """
  @spec encode_envelope(envelope()) :: binary() | {:error, String.t()}
  def encode_envelope(envelope) when is_map(envelope),
    do: Kernel.runtime_fabric_encode_envelope(envelope)

  @doc """
  Decodes RuntimeFabric protobuf bytes into the public envelope map.
  """
  @spec decode_envelope(binary()) :: envelope() | {:error, String.t()}
  def decode_envelope(bytes) when is_binary(bytes),
    do: Kernel.runtime_fabric_decode_envelope(bytes)

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
  """
  @spec router_send_mandatory(router(), String.t(), envelope()) ::
          {:ok, :sent_or_queued} | {:error, atom() | String.t()}
  def router_send_mandatory(router, transport_route, envelope)
      when is_binary(transport_route) and is_map(envelope) do
    envelope_json = Torque.encode!(envelope)

    case Kernel.runtime_fabric_router_send_mandatory(router, transport_route, envelope_json) do
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
