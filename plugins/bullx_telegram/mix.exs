defmodule BullxTelegram.MixProject do
  use Mix.Project

  def project do
    [
      app: :bullx_telegram,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps()
    ]
  end

  defp deps do
    [
      {:telegram, github: "visciang/telegram", tag: "2.1.1"}
    ]
  end
end
