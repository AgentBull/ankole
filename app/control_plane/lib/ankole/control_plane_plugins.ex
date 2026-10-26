defmodule Ankole.ControlPlanePlugins do
  @moduledoc """
  Operator-facing projection of compiled Elixir/OTP Control Plane Plugins.

  Configuration is durable but activation is boot-time. Writes only change the
  next-start selection; the active registry remains the truth for this process.
  """

  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  json_api do
    authorize?(true)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/control-plane-plugins", Ankole.ControlPlanePlugins.Console do
        route(:get, "/", :list, name: "list_control_plane_plugins", wrap_in_result?: false)

        route(:put, "/", :configure,
          name: "configure_control_plane_plugin",
          wrap_in_result?: false
        )
      end
    end
  end

  resources do
    resource(Ankole.ControlPlanePlugins.Console)
  end

  defdelegate list(), to: Ankole.ControlPlanePlugins.Console.Actions
end
