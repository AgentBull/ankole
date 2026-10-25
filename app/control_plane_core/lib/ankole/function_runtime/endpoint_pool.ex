defmodule Ankole.FunctionRuntime.EndpointPool do
  @moduledoc "Resolves function replicas and leases the least occupied endpoint."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def checkout(excluded \\ []), do: GenServer.call(__MODULE__, {:checkout, excluded})
  def release(lease), do: GenServer.cast(__MODULE__, {:release, lease})
  def unavailable(endpoint), do: GenServer.cast(__MODULE__, {:unavailable, endpoint.ip})

  def authorization do
    token = Application.fetch_env!(:ankole, :function_runtime) |> Keyword.fetch!(:token)
    [{"authorization", "Bearer " <> token}]
  end

  @impl true
  def init(_opts) do
    config = Application.fetch_env!(:ankole, :function_runtime)
    uri = URI.parse(Keyword.fetch!(config, :url))
    {:ok, refresh(%{uri: uri, endpoints: %{}, leases: %{}})}
  end

  @impl true
  def handle_call({:checkout, excluded}, {owner, _}, state) do
    now = System.monotonic_time(:millisecond)
    occupancy = Enum.frequencies(Map.values(state.leases))

    candidates =
      state.endpoints |> Map.values() |> Enum.reject(&(&1.ip in excluded or &1.cooldown > now))

    case Enum.shuffle(candidates) |> Enum.min_by(&Map.get(occupancy, &1.ip, 0), fn -> nil end) do
      nil ->
        {:reply, {:error, :function_runtime_unavailable}, state}

      endpoint ->
        monitor = Process.monitor(owner)
        {:reply, {:ok, endpoint, monitor}, put_in(state.leases[monitor], endpoint.ip)}
    end
  end

  @impl true
  def handle_cast({:release, lease}, state), do: {:noreply, release_lease(state, lease)}

  def handle_cast({:unavailable, ip}, state) do
    state =
      case Map.fetch(state.endpoints, ip) do
        {:ok, endpoint} ->
          put_in(state.endpoints[ip], %{
            endpoint
            | cooldown: System.monotonic_time(:millisecond) + 2_000
          })

        :error ->
          state
      end

    send(self(), :refresh_now)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, lease, :process, _, _}, state),
    do: {:noreply, release_lease(state, lease)}

  def handle_info(:refresh, state), do: {:noreply, refresh(state)}
  def handle_info(:refresh_now, state), do: {:noreply, resolve(state)}

  defp release_lease(state, lease) do
    case Map.pop(state.leases, lease) do
      {nil, _} ->
        state

      {_ip, leases} ->
        Process.demonitor(lease, [:flush])
        %{state | leases: leases}
    end
  end

  defp refresh(state) do
    Process.send_after(self(), :refresh, 5_000)
    resolve(state)
  end

  defp resolve(%{uri: uri} = state) do
    addresses =
      for family <- [:inet, :inet6],
          {:ok, ips} <- [:inet.getaddrs(String.to_charlist(uri.host), family)],
          ip <- ips,
          do: ip

    endpoints =
      Map.new(addresses, fn ip ->
        endpoint =
          Map.get(state.endpoints, ip) ||
            %{
              ip: ip,
              port: uri.port,
              host: uri.host,
              scheme: String.to_existing_atom(uri.scheme),
              url: URI.to_string(%{uri | host: to_string(:inet.ntoa(ip)), path: nil}),
              cooldown: System.monotonic_time(:millisecond)
            }

        {ip, endpoint}
      end)

    %{state | endpoints: endpoints}
  end
end
