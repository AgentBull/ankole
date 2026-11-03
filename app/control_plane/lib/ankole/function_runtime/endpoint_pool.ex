defmodule Ankole.FunctionRuntime.EndpointPool do
  @moduledoc "Resolves function replicas and leases the least occupied endpoint."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def checkout(excluded \\ [], action_url \\ nil),
    do: GenServer.call(__MODULE__, {:checkout, excluded, action_url})

  def release(lease), do: GenServer.cast(__MODULE__, {:release, lease})

  def unavailable(endpoint),
    do: GenServer.cast(__MODULE__, {:unavailable, endpoint.ip, Map.get(endpoint, :action_url)})

  def authorization do
    token = Application.fetch_env!(:ankole, :function_runtime) |> Keyword.fetch!(:token)
    [{"authorization", "Bearer " <> token}]
  end

  @impl true
  def init(_opts) do
    config = Application.fetch_env!(:ankole, :function_runtime)
    uri = URI.parse(Keyword.fetch!(config, :url))

    {:ok,
     refresh(%{uri: uri, endpoints: %{}, leases: %{}, action_url: nil, action_endpoints: %{}})}
  end

  @impl true
  def handle_call({:checkout, excluded, action_url}, {owner, _}, state) do
    state = action_endpoints(state, action_url)
    endpoints = if action_url, do: state.action_endpoints, else: state.endpoints
    now = System.monotonic_time(:millisecond)
    occupancy = Enum.frequencies(Map.values(state.leases))

    candidates =
      endpoints |> Map.values() |> Enum.reject(&(&1.ip in excluded or &1.cooldown > now))

    case Enum.shuffle(candidates)
         |> Enum.min_by(&Map.get(occupancy, lease_key(&1), 0), fn -> nil end) do
      nil ->
        {:reply, {:error, :function_runtime_unavailable}, state}

      endpoint ->
        monitor = Process.monitor(owner)
        {:reply, {:ok, endpoint, monitor}, put_in(state.leases[monitor], lease_key(endpoint))}
    end
  end

  @impl true
  def handle_cast({:release, lease}, state), do: {:noreply, release_lease(state, lease)}

  def handle_cast({:unavailable, ip, action_url}, state) do
    key = if action_url, do: :action_endpoints, else: :endpoints

    state =
      case Map.fetch(state[key], ip) do
        {:ok, %{action_url: ^action_url} = endpoint} ->
          put_in(state[key][ip], %{
            endpoint
            | cooldown: System.monotonic_time(:millisecond) + 2_000
          })

        _ ->
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
    state = %{state | endpoints: resolve_endpoints(uri, state.endpoints)}

    if state.action_url do
      %{
        state
        | action_endpoints:
            resolve_endpoints(
              URI.parse(state.action_url),
              state.action_endpoints,
              state.action_url
            )
      }
    else
      state
    end
  end

  defp action_endpoints(state, nil), do: state
  defp action_endpoints(%{action_url: url} = state, url), do: state

  defp action_endpoints(state, url),
    do: %{state | action_url: url, action_endpoints: resolve_endpoints(URI.parse(url), %{}, url)}

  defp lease_key(%{action_url: url, ip: ip}) when is_binary(url), do: {url, ip}
  defp lease_key(endpoint), do: endpoint.ip

  defp resolve_endpoints(uri, previous, action_url \\ nil) do
    addresses =
      for family <- [:inet, :inet6],
          {:ok, ips} <- [:inet.getaddrs(String.to_charlist(uri.host), family)],
          ip <- ips,
          do: ip

    Map.new(addresses, fn ip ->
      endpoint =
        Map.get(previous, ip) ||
          %{
            action_url: action_url,
            ip: ip,
            port: uri.port,
            host: uri.host,
            scheme: String.to_existing_atom(uri.scheme),
            url: URI.to_string(%{uri | host: to_string(:inet.ntoa(ip)), path: nil}),
            cooldown: System.monotonic_time(:millisecond)
          }

      {ip, endpoint}
    end)
  end
end
