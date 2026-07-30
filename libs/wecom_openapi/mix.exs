defmodule WeComOpenAPI.MixProject do
  use Mix.Project

  @description "Thin Elixir client for WeCom (企业微信): AI bot WebSocket channel, corp REST API, WWLogin, and contacts."
  @repo_url "https://github.com/agentbull/ankole"
  @source_root "libs/wecom_openapi"
  @source_url "#{@repo_url}/tree/main/#{@source_root}"
  @hexdocs_url "https://hexdocs.pm/wecom_openapi"

  def project do
    [
      app: :wecom_openapi,
      name: "WeComOpenAPI",
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {WeComOpenAPI.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.6.2"},
      {:torque, "~> 0.2.3"},
      {:telemetry, "~> 1.4.2"},
      {:mint_web_socket, "~> 1.0"},
      {:plug, "~> 1.19", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp description, do: @description

  defp package do
    [
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* NOTICE*),
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Documentation" => @hexdocs_url,
        "WeCom Developer Center" => "https://developer.work.weixin.qq.com"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "README.zh-Hans.md": [title: "README (简体中文)", filename: "readme.zh-hans"]
      ],
      extra_section: "Guides",
      source_ref: "main",
      source_url_pattern: "#{@repo_url}/blob/main/#{@source_root}/%{path}#L%{line}"
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
