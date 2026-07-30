defmodule Ankole.E2E.FakeWeCom.Server do
  @moduledoc false

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias Ankole.E2E.FakeWeCom.{Router, State}

  def start!(opts \\ []) do
    state = start_supervised!({State, opts})

    server =
      start_supervised!(
        {Bandit,
         plug: {Router, state: state},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{state: state, ws_url: "ws://127.0.0.1:#{port}/", port: port}
  end
end
