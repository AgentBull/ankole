defmodule MicrosoftOpenAPI.MixProject do
  use Mix.Project

  def project do
    [
      app: :microsoft_openapi,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {MicrosoftOpenAPI.Application, []}]
  end

  defp deps do
    [
      {:req, "~> 0.6.2"},
      {:torque, "~> 0.2.3"},
      {:telemetry, "~> 1.4.2"},
      {:plug, "~> 1.19", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
