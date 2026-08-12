defmodule FakeFeishu.MixProject do
  use Mix.Project

  def project do
    [
      app: :fake_feishu,
      version: "0.1.0",
      elixir: "~> 1.20",
      # `platform/` holds the fake Feishu platform core that the control-plane
      # e2e suites also compile (see app/control_plane/mix.exs); `lib/` holds
      # the standalone server, admin API, and CLI.
      elixirc_paths: ["lib", "platform"],
      deps: deps(),
      escript: [main_module: FakeFeishu.CLI, name: "fake-feishu"],
      start_permanent: false
    ]
  end

  def application do
    [extra_applications: [:logger, :inets, :ssl]]
  end

  defp deps do
    [
      {:bandit, "~> 1.12"},
      {:websock_adapter, "~> 0.6"},
      {:feishu_openapi, path: "../../libs/feishu_openapi"}
    ]
  end
end
