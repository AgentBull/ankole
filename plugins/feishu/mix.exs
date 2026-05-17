defmodule Feishu.MixProject do
  use Mix.Project

  def project do
    [
      app: :feishu,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps()
    ]
  end

  defp deps do
    [
      {:feishu_openapi, path: Path.expand("../../packages/feishu_openapi", __DIR__)},
      {:mint_web_socket, "~> 1.0"}
    ]
  end
end
