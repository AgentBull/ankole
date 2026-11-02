defmodule Ankole.Files.Vfs.Attachments do
  @moduledoc "Flushes local Drive paths before the delivery owner freezes their immutable bytes."
  alias Ankole.AgentWorkers
  alias Ankole.RuntimeFabric.V1, as: Proto

  def resolve(run, "reply_attachment", %{"path" => path} = args) when is_binary(path) do
    with {:ok, [id]} <- flush(run, [path]),
         do: {:ok, args |> Map.delete("path") |> Map.put("node_id", id)}
  end

  def resolve(run, "send_message", %{"attachments" => paths} = args) when is_list(paths) do
    remote_paths = Enum.reject(paths, &match?({:ok, _}, Ecto.UUID.cast(&1)))

    with {:ok, ids} <- flush(run, remote_paths) do
      resolved = Map.new(Enum.zip(remote_paths, ids))
      {:ok, Map.put(args, "attachments", Enum.map(paths, &Map.get(resolved, &1, &1)))}
    end
  end

  def resolve(_run, _name, args), do: {:ok, args}

  defp flush(_run, []), do: {:ok, []}

  defp flush(run, paths) do
    with {:ok, config} when not is_nil(config) <-
           Ankole.Files.Vfs.Auth.runtime_config(run.agent_uid, run.signal_id),
         {:ok, worker} <- AgentWorkers.connected_worker(run.agent_uid),
         {payload, _size} <-
           Proto.VfsFlushRequest.encode!(%Proto.VfsFlushRequest{
             view_key: config.view,
             paths: paths
           }),
         {:ok, bytes} <-
           AgentWorkers.WorkerRoute.request_rpc(
             AgentWorkers.target(worker),
             "vfs.flush",
             IO.iodata_to_binary(payload),
             timeout_ms: 120_000
           ),
         {:ok, reply} <- Proto.VfsFlushResponse.decode(bytes),
         do: {:ok, reply.node_ids},
         else: (
           {:ok, nil} -> {:error, :drive_not_mounted}
           error -> error
         )
  end
end
