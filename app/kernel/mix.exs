defmodule AnkoleKernel.MixProject do
  use Mix.Project

  def project do
    [
      app: :ankole_kernel,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.38.0", runtime: false},
      {:torque, "~> 0.2.3"}
    ]
  end
end
