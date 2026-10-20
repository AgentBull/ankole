defmodule IMTransport.MixProject do
  use Mix.Project

  def project do
    [
      app: :im_transport,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps_path: "../../app/control_plane/deps",
      lockfile: "../../app/control_plane/mix.lock",
      deps: [{:req, "~> 0.7.3"}, {:torque, "~> 0.5.0"}, {:mint_web_socket, "~> 1.0"}]
    ]
  end
end
