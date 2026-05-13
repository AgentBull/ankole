defmodule Discord.MixProject do
  use Mix.Project

  def project do
    [
      app: :discord,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps()
    ]
  end

  defp deps do
    [
      {:nostrum,
       github: "Kraigie/nostrum",
       ref: "03b06ba1c5094b83991097b1ce76b5fe2740324c",
       runtime: false}
    ]
  end
end
