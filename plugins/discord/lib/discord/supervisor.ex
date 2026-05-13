defmodule Discord.Supervisor do
  @moduledoc """
  Per-source one-for-all supervisor.

  Wraps `Discord.Channel` and the per-source `Nostrum.Bot` subtree so the
  `BullX.Gateway.Adapter.source_child_spec/1` single-child contract returns
  one spec. If either child crashes the other restarts so cache state stays
  consistent with the Discord Gateway connection.

  Disabled or test-mode sources (`Discord.Source.start_transport? == false`)
  start only the channel; the Nostrum bot is omitted.
  """

  use Supervisor

  alias BullX.Gateway.SourceConfig
  alias Discord.{Channel, Source}

  @spec child_spec(SourceConfig.t()) :: Supervisor.child_spec()
  def child_spec(%SourceConfig{} = source_config) do
    %{
      id: {__MODULE__, source_config.adapter, source_config.channel_id},
      start: {__MODULE__, :start_link, [source_config]},
      restart: :permanent,
      type: :supervisor
    }
  end

  @spec start_link(SourceConfig.t()) :: Supervisor.on_start()
  def start_link(%SourceConfig{} = source_config) do
    Supervisor.start_link(__MODULE__, source_config,
      name: {:via, Registry, {Discord.Registry, {:supervisor, source_config.channel_id}}}
    )
  end

  @impl true
  def init(%SourceConfig{} = source_config) do
    with {:ok, %Source{} = source} <- Source.normalize(source_config) do
      children =
        [{Channel, {source_config, source}}]
        |> maybe_add_bot(source)

      Supervisor.init(children, strategy: :one_for_all)
    else
      {:error, error} -> {:stop, {:discord_supervisor_init_failed, error}}
    end
  end

  defp maybe_add_bot(children, %Source{start_transport?: false}), do: children

  defp maybe_add_bot(children, %Source{nostrum_bot_module: module} = source) do
    case function_exported?(module, :child_spec, 1) do
      true ->
        children ++ [{module, Source.bot_options(source)}]

      false ->
        children
    end
  end
end
