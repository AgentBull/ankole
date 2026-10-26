defmodule Ankole.FunctionRuntime.HTTP do
  @moduledoc false
  alias Ankole.FunctionRuntime.EndpointPool

  def request(method, path, body, timeout \\ 65_000, observer \\ nil),
    do: attempt(method, path, body, timeout, [], observer)

  def at(endpoint, method, path, body, timeout, observer \\ nil) do
    deadline = System.monotonic_time(:millisecond) + timeout

    request =
      Finch.build(
        method,
        endpoint.url <> path,
        [{"content-type", "application/json"} | EndpointPool.authorization()],
        if(method in [:get, :delete], do: nil, else: Torque.encode!(body))
      )

    ref =
      Finch.async_request(request, Ankole.FunctionRuntime.Finch,
        pool_timeout: timeout,
        receive_timeout: timeout,
        request_timeout: timeout
      )

    if observer do
      {owner, handle} = observer
      send(owner, {:function_runtime_request, handle, ref})
    end

    try do
      receive_response(ref, nil, [], deadline)
    after
      Finch.cancel_async_request(ref)
    end
  end

  defp attempt(method, path, body, timeout, excluded, observer) do
    with {:ok, endpoint, lease} <- EndpointPool.checkout(excluded) do
      try do
        case at(endpoint, method, path, body, timeout, observer) do
          result when excluded == [] ->
            if retryable?(result) do
              EndpointPool.unavailable(endpoint)
              attempt(method, path, body, timeout, [endpoint.ip], observer)
            else
              result
            end

          result ->
            result
        end
      after
        EndpointPool.release(lease)
      end
    end
  end

  defp retryable?({:ok, 503, _}), do: true
  defp retryable?({:connect_error, _}), do: true
  defp retryable?(_), do: false

  defp receive_response(ref, status, body, deadline) do
    receive do
      {^ref, {:status, value}} ->
        receive_response(ref, value, body, deadline)

      {^ref, {:headers, _}} ->
        receive_response(ref, status, body, deadline)

      {^ref, {:data, bytes}} ->
        receive_response(ref, status, [bytes | body], deadline)

      {^ref, :done} ->
        {:ok, status, body |> Enum.reverse() |> IO.iodata_to_binary()}

      {^ref, {:error, %{reason: reason}}}
      when is_nil(status) and reason in [:econnrefused, :enetunreach, :ehostunreach, :nxdomain] ->
        {:connect_error, reason}

      {^ref, {:error, reason}} ->
        {:error, reason}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        {:error, :function_runtime_timeout}
    end
  end
end
