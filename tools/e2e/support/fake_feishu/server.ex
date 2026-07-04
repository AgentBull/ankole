defmodule Ankole.E2E.FakeFeishu.Server do
  @moduledoc """
  Starts one fake Feishu platform (State + Bandit HTTP/WS listener) under the
  current ExUnit test supervisor and returns its handle.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias Ankole.E2E.FakeFeishu.Router
  alias Ankole.E2E.FakeFeishu.State

  @type t :: %{state: pid(), base_url: String.t(), port: :inet.port_number()}

  @doc """
  Starts the fake platform and registers the given app credentials.

  Options: `:owner` (defaults to the calling test process) and `:apps`
  (list of `{app_id, app_secret}` accepted by the auth endpoints).
  """
  @spec start!(keyword()) :: t()
  def start!(opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    state = start_supervised!({State, owner: owner})

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

    for {app_id, app_secret} <- Keyword.get(opts, :apps, []) do
      :ok = State.register_app(state, app_id, app_secret)
    end

    %{state: state, base_url: "http://127.0.0.1:#{port}", port: port}
  end
end
