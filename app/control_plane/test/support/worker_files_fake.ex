defmodule Ankole.WorkerFilesFake do
  @moduledoc """
  In-process stand-in for the Worker side of `worker_files.*` RPCs.

  The fake registers a local WorkerRoute route, answers each RPC from an in-memory
  file map, and performs the relay `GET`/`PUT` against `AnkoleWeb.Endpoint`
  with `Phoenix.ConnTest`, so tests exercise the real signed-URL relay path.

  Files are keyed by their path in the Agent Home.

  Options:

    * `:files` — initial `%{home_relative_path => content}` map;
    * `:on_read` — `(home_relative_path -> {:ok, content} | {:error, {code, message}})`
      override for push;
    * `:on_bundle` — `(request -> {:ok, body} | {:error, {code, message}})`
      override for the body of a bundle push;
    * `:fail` — `%{operation => {code, message}}` that makes an operation
      answer with `rpc_error`;
    * `:http` — uses a real HTTP request for push integration tests; defaults to ConnTest.
    * `:tamper_token` — when true, the relay request carries a wrong token.

  A push with `bundle_paths` answers with the bundle of those files, as the
  Worker relay does.
  """

  import Phoenix.ConnTest, only: [build_conn: 0, dispatch: 5]
  import Plug.Conn, only: [put_req_header: 3]

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.AgentWorkers.WorkerRoute

  @endpoint AnkoleWeb.Endpoint

  @doc """
  Starts the fake for `route` and registers it as the local WorkerRoute worker.
  """
  @spec start!(String.t(), keyword()) :: pid()
  def start!(route, opts \\ []) do
    state = %{
      route: route,
      files: Keyword.get(opts, :files, %{}),
      writes: [],
      pushes: [],
      on_read: Keyword.get(opts, :on_read),
      on_bundle: Keyword.get(opts, :on_bundle),
      fail: Keyword.get(opts, :fail, %{}),
      tamper_token: Keyword.get(opts, :tamper_token, false),
      http: Keyword.get(opts, :http, false)
    }

    pid = spawn_link(fn -> loop(state) end)
    :ok = WorkerRoute.register_local_worker(route, pid)

    ExUnit.Callbacks.on_exit(fn ->
      WorkerRoute.unregister_local_worker(route)
      if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    end)

    pid
  end

  @doc """
  Returns the current `%{home_relative_path => content}` map.
  """
  @spec files(pid()) :: map()
  def files(pid), do: call(pid, :files)

  @doc """
  Returns every completed pull as `%{path: home_relative_path, content: binary}`, oldest first.
  """
  @spec writes(pid()) :: [map()]
  def writes(pid), do: call(pid, :writes)

  @doc """
  Returns every push request as `%{home_relative_path: path, bundle_paths: paths}`, oldest first.
  """
  @spec pushes(pid()) :: [map()]
  def pushes(pid), do: call(pid, :pushes)

  defp call(pid, request) do
    ref = make_ref()
    send(pid, {request, self(), ref})

    receive do
      {^ref, reply} -> reply
    after
      5_000 -> raise "worker files fake did not answer #{inspect(request)}"
    end
  end

  defp loop(state) do
    receive do
      {:files, from, ref} ->
        send(from, {ref, state.files})
        loop(state)

      {:writes, from, ref} ->
        send(from, {ref, Enum.reverse(state.writes)})
        loop(state)

      {:pushes, from, ref} ->
        send(from, {ref, Enum.reverse(state.pushes)})
        loop(state)

      {:actor_lane, %FabricProto.Envelope{body: {:rpc_request, request}}} ->
        {reply, state} = handle(request, state)
        WorkerRoute.local_inbound(state.route, encode(reply, request))
        loop(state)

      {:actor_lane, _envelope} ->
        loop(state)
    end
  end

  defp handle(%FabricProto.RPCRequest{method: "worker_files." <> operation} = request, state) do
    case Map.get(state.fail, operation) do
      {code, message} -> {{:error, code, message}, state}
      nil -> operate(operation, request.payload, state)
    end
  end

  defp handle(request, state) do
    {{:error, "unknown_rpc_method", "unknown worker RPC method: #{request.method}"}, state}
  end

  defp operate("pull", payload, state) do
    {:ok, request} = FabricProto.WorkerFileTransferRequest.decode(payload)
    path = request.home_relative_path
    conn = dispatch(build_conn(), @endpoint, :get, relay_path(state, request.url), nil)

    if conn.status == 200 do
      content = conn.resp_body

      {{:ok, %FabricProto.WorkerFileTransferResponse{size: byte_size(content)}},
       %{
         state
         | files: Map.put(state.files, path, content),
           writes: [%{path: path, content: content} | state.writes]
       }}
    else
      {{:error, "relay_failed", "relay GET answered #{conn.status}"}, state}
    end
  end

  defp operate("push", payload, state) do
    {:ok, request} = FabricProto.WorkerFileTransferRequest.decode(payload)

    state = %{
      state
      | pushes: [
          %{home_relative_path: request.home_relative_path, bundle_paths: request.bundle_paths}
          | state.pushes
        ]
    }

    case push_content(state, request) do
      {:ok, content} when byte_size(content) > request.max_bytes ->
        {{:error, "file_too_large", "file exceeds #{request.max_bytes} bytes"}, state}

      {:ok, content} ->
        status =
          if state.http do
            Req.put!(request.url,
              body: content,
              headers: [{"content-type", "application/octet-stream"}],
              retry: false,
              receive_timeout: 120_000
            ).status
          else
            conn =
              build_conn()
              |> put_req_header("content-type", "application/octet-stream")
              |> put_req_header("content-length", Integer.to_string(byte_size(content)))
              |> dispatch(@endpoint, :put, relay_path(state, request.url), content)

            conn.status
          end

        if status == 200 do
          {{:ok, %FabricProto.WorkerFileTransferResponse{size: byte_size(content)}}, state}
        else
          {{:error, "relay_failed", "relay PUT answered #{status}"}, state}
        end

      {:error, {code, message}} ->
        {{:error, code, message}, state}
    end
  end

  defp push_content(state, %{bundle_paths: []} = request),
    do: read(state, request.home_relative_path)

  defp push_content(%{on_bundle: on_bundle}, request) when is_function(on_bundle, 1),
    do: on_bundle.(request)

  defp push_content(state, request) do
    Enum.reduce_while(request.bundle_paths, {:ok, []}, fn path, {:ok, parts} ->
      case read(state, request.home_relative_path <> "/" <> path) do
        {:ok, content} ->
          entry = [
            <<byte_size(path)::32-big>>,
            path,
            <<byte_size(content)::64-big>>,
            content
          ]

          {:cont, {:ok, [entry | parts]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary()}
      error -> error
    end
  end

  defp read(%{on_read: on_read}, path) when is_function(on_read, 1), do: on_read.(path)

  defp read(state, path) do
    case Map.fetch(state.files, path) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, {"file_not_found", "path does not exist: #{path}"}}
    end
  end

  defp relay_path(state, url) do
    %URI{path: path, query: query} = URI.parse(url)
    if state.tamper_token, do: path <> "?" <> query <> "x", else: path <> "?" <> query
  end

  defp encode({:ok, response}, request) do
    {iodata, _size} = response.__struct__.encode!(response)

    reply_envelope(
      request,
      {:rpc_response,
       %FabricProto.RPCResponse{
         request_id: request.request_id,
         payload: IO.iodata_to_binary(iodata)
       }}
    )
  end

  defp encode({:error, code, message}, request) do
    reply_envelope(
      request,
      {:rpc_error,
       %FabricProto.RPCError{
         request_id: request.request_id,
         code: code,
         message: message,
         details_json: JSON.encode!(%{retryable: false})
       }}
    )
  end

  defp reply_envelope(_request, body) do
    Ankole.Kernel.RuntimeFabric.encode_envelope(%FabricProto.Envelope{
      message_id: "worker-files-fake-#{System.unique_integer([:positive])}",
      body: body
    })
  end
end
