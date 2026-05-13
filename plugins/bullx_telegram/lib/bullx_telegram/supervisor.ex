defmodule BullxTelegram.Supervisor do
  @moduledoc """
  One-for-all per-source supervisor.

  Wraps `BullxTelegram.Channel` and `BullxTelegram.Poller` as siblings (the
  shape `lib/bullx_telegram/` used on main) so the new
  `BullX.Gateway.Adapter.source_child_spec/1` single-child contract can return
  one spec instead of two. If either child crashes, both restart so cache
  state stays consistent with the polling offset.
  """

  use Supervisor

  alias BullxTelegram.{Channel, Poller, Source}

  @spec child_spec(BullX.Gateway.SourceConfig.t()) :: Supervisor.child_spec()
  def child_spec(%BullX.Gateway.SourceConfig{} = source_config) do
    %{
      id: {__MODULE__, source_config.adapter, source_config.channel_id},
      start: {__MODULE__, :start_link, [source_config]},
      restart: :permanent,
      type: :supervisor
    }
  end

  @spec start_link(BullX.Gateway.SourceConfig.t()) :: Supervisor.on_start()
  def start_link(%BullX.Gateway.SourceConfig{} = source_config) do
    Supervisor.start_link(__MODULE__, source_config,
      name: {:via, Registry, {BullxTelegram.Registry, {:supervisor, source_config.channel_id}}}
    )
  end

  @impl true
  def init(%BullX.Gateway.SourceConfig{} = source_config) do
    with {:ok, source} <- Source.normalize(source_config) do
      children = [
        {Channel, {source_config, source}},
        {Poller, {source_config, source}}
      ]

      Supervisor.init(children, strategy: :one_for_all)
    else
      {:error, error} -> {:stop, {:telegram_supervisor_init_failed, error}}
    end
  end
end
