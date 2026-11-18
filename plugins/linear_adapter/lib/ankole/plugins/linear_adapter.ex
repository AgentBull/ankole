defmodule Ankole.Plugins.LinearAdapter do
  @moduledoc "Linear's official remote MCP service as a tenant-owned connector."
  @behaviour Ankole.Plugins.Plugin
  def plugin_id, do: "linear-adapter"
  def activation, do: :always
  def display_name, do: %{"default" => "Linear"}

  def description,
    do: %{
      "default" => "Issues, projects, cycles, comments, teams, and labels through Linear MCP."
    }

  def adapter_declarations do
    [
      %{
        contract_id: "connectors.connector",
        id: "linear",
        plugin_id: plugin_id(),
        module: Ankole.Plugins.LinearAdapter.Connector,
        auth_schemes: ["oauth2"],
        credential_fields: [
          %{
            key: "clientID",
            label: %{
              "default" => "OAuth client ID",
              "zh-Hans-CN" => "OAuth 客户端 ID",
              "ja-JP" => "OAuth クライアント ID",
              "ko-KR" => "OAuth 클라이언트 ID"
            },
            secret: false,
            required: true
          },
          %{
            key: "clientSecret",
            label: %{
              "default" => "OAuth client secret",
              "zh-Hans-CN" => "OAuth 客户端密钥",
              "ja-JP" => "OAuth クライアントシークレット",
              "ko-KR" => "OAuth 클라이언트 시크릿"
            },
            secret: true,
            required: true
          }
        ]
      }
    ]
  end
end
