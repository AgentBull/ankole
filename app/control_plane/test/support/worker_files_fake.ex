defmodule Ankole.WorkerFilesFake do
  @moduledoc """
  In-process stand-in for the Worker side of `worker_files.*` RPCs.

  The fake registers a local WorkerRoute route, answers each RPC from an in-memory
  file map, and performs the relay `GET`/`PUT` against `AnkoleWeb.Endpoint`
  with `Phoenix.ConnTest`, so tests exercise the real signed-URL relay path.

  Options:

    * `:files` — initial `%{"/root/relative" => content}` map;
    * `:notify` — pid that receives `{:materialized_attachment_path, path}`
      after each successful pull;
    * `:on_read` — `(virtual_path -> {:ok, content} | {:error, {code, message}})`
      override for push;
    * `:fail` — `%{operation => {code, message}}` that makes an operation
      answer with `rpc_error`;
    * `:tamper_token` — when true, the relay request carries a wrong token.
  """

  import Phoenix.ConnTest, only: [build_conn: 0, dispatch: 5]
  import Plug.Conn, only: [put_req_header: 3]

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRoute

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
      notify: Keyword.get(opts, :notify),
      on_read: Keyword.get(opts, :on_read),
      fail: Keyword.get(opts, :fail, %{}),
      tamper_token: Keyword.get(opts, :tamper_token, false)
    }

    pid = spawn_link(fn -> loop(state) end)
    :ok = WorkerRoute.register_local_worker(route, pid)
    ExUnit.Callbacks.on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    pid
  end

  @doc """
  Returns the current `%{"/root/relative" => content}` map.
  """
  @spec files(pid()) :: map()
  def files(pid), do: call(pid, :files)

  @doc """
  Returns every completed pull as `%{path: virtual_path, content: binary}`, oldest first.
  """
  @spec writes(pid()) :: [map()]
  def writes(pid), do: call(pid, :writes)

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
    path = virtual_path(request.root, request.relative_path)
    conn = dispatch(build_conn(), @endpoint, :get, relay_path(state, request.url), nil)

    if conn.status == 200 do
      content = conn.resp_body
      if state.notify, do: send(state.notify, {:materialized_attachment_path, path})

      {{:ok,
        %FabricProto.WorkerFileTransferResponse{
          root: request.root,
          relative_path: request.relative_path,
          size: byte_size(content),
          xxh3_128: "8db84f6b892cfa6bdad930c907ecb808"
        }},
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
    path = virtual_path(request.root, request.relative_path)

    case read(state, path) do
      {:ok, content} when byte_size(content) > request.max_bytes ->
        {{:error, "file_too_large", "file exceeds #{request.max_bytes} bytes"}, state}

      {:ok, content} ->
        conn =
          build_conn()
          |> put_req_header("content-type", "application/octet-stream")
          |> put_req_header("content-length", Integer.to_string(byte_size(content)))
          |> dispatch(@endpoint, :put, relay_path(state, request.url), content)

        if conn.status == 200 do
          {{:ok,
            %FabricProto.WorkerFileTransferResponse{
              root: request.root,
              relative_path: request.relative_path,
              size: byte_size(content),
              xxh3_128: ""
            }}, state}
        else
          {{:error, "relay_failed", "relay PUT answered #{conn.status}"}, state}
        end

      {:error, {code, message}} ->
        {{:error, code, message}, state}
    end
  end

  defp operate("list", payload, state) do
    {:ok, request} = FabricProto.WorkerFileListRequest.decode(payload)
    prefix = virtual_path(request.root, request.relative_path)

    entries =
      state.files
      |> Enum.filter(fn {path, _content} -> String.starts_with?(path, prefix <> "/") end)
      |> Enum.sort()
      |> Enum.map(fn {path, content} ->
        %FabricProto.WorkerFileListEntry{
          relative_path: String.replace_prefix(path, "/#{request.root}/", ""),
          kind: "file",
          size: byte_size(content),
          modified_unix_ms: 1_772_000_000_000
        }
      end)

    {{:ok,
      %FabricProto.WorkerFileListResponse{
        root: request.root,
        relative_path: request.relative_path,
        truncated: false,
        entries: entries
      }}, state}
  end

  defp operate("move", payload, state) do
    {:ok, request} = FabricProto.WorkerFileMoveRequest.decode(payload)
    from = virtual_path(request.root, request.from_relative_path)
    to = virtual_path(request.root, request.to_relative_path)

    case Map.pop(state.files, from) do
      {nil, _files} ->
        {{:error, "file_not_found", "path does not exist: #{from}"}, state}

      {content, files} ->
        {{:ok,
          %FabricProto.WorkerFileMoveResponse{
            root: request.root,
            from_relative_path: request.from_relative_path,
            to_relative_path: request.to_relative_path
          }}, %{state | files: Map.put(files, to, content)}}
    end
  end

  defp operate("delete", payload, state) do
    {:ok, request} = FabricProto.WorkerFileDeleteRequest.decode(payload)
    path = virtual_path(request.root, request.relative_path)

    if Map.has_key?(state.files, path) do
      {{:ok,
        %FabricProto.WorkerFileDeleteResponse{
          root: request.root,
          relative_path: request.relative_path
        }}, %{state | files: Map.delete(state.files, path)}}
    else
      {{:error, "file_not_found", "path does not exist: #{path}"}, state}
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

  defp virtual_path(root, ""), do: "/" <> root
  defp virtual_path(root, relative_path), do: "/" <> root <> "/" <> relative_path

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

  defp reply_envelope(request, body) do
    Ankole.Kernel.RuntimeFabric.encode_envelope(%FabricProto.Envelope{
      message_id: "worker-files-fake-#{System.unique_integer([:positive])}",
      correlation_id: request.request_id,
      lane: :LANE_RPC,
      durability: :CONTROL_EPHEMERAL,
      sent_at_unix_ms: System.system_time(:millisecond),
      body: body
    })
  end
end
