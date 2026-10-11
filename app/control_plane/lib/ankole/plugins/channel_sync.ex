defmodule Ankole.Plugins.ChannelSync do
  @moduledoc """
  Enqueues the full sync jobs that rebuild an adapter's mirrored chat channels.

  The Lark IM group, Slack channel, and Teams channel projections each own an
  Oban worker that rebuilds the projection for one binding. This module enqueues
  that worker once for every enabled binding at plugin startup, and for one
  binding when the binding is saved.
  """

  alias Ankole.Logging
  alias Ankole.Repo
  alias Ankole.Tenants
  alias Ankole.SignalsGateway

  @doc """
  Starts a one-time task that enqueues a full sync for every enabled binding.

  Options: `:adapter` is the binding adapter id and `:worker` is the Oban worker
  that syncs one binding.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    worker = Keyword.fetch!(opts, :worker)

    %{
      id: {__MODULE__, adapter},
      start: {Task, :start_link, [fn -> enqueue_enabled_bindings(adapter, worker) end]},
      restart: :temporary
    }
  end

  @doc "Enqueues one full sync of the channels that one binding serves."
  @spec enqueue_binding(module(), String.t(), String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_binding(worker, agent_uid, binding_name, opts \\ [])
      when is_atom(worker) and is_binary(agent_uid) and is_binary(binding_name) do
    %{
      "agent_uid" => String.downcase(agent_uid),
      "binding_name" => binding_name,
      "reason" => to_string(Keyword.get(opts, :reason, "manual")),
      "source" => to_string(Keyword.get(opts, :source, "manual"))
    }
    |> worker.new()
    |> Oban.insert()
  end

  defp enqueue_enabled_bindings(adapter, worker) do
    Repo.across_tenants(fn -> SignalsGateway.list_enabled_bindings(adapter) end)
    |> Enum.reduce_while(:ok, fn binding, :ok ->
      Repo.with_tenant(binding.tenant_id, fn ->
        result =
          if Tenants.accepting_work?(binding.tenant_id),
            do:
              enqueue_binding(worker, binding.agent_uid, binding.name,
                reason: "startup",
                source: "startup"
              ),
            else: {:ok, :skipped}

        case result do
          {:ok, _job} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end)
    |> case do
      :ok ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "plugins.channel_sync.startup_enqueue_failed",
          "startup channel sync enqueue failed",
          %{adapter: adapter, reason: inspect(reason)}
        )
    end
  end
end
