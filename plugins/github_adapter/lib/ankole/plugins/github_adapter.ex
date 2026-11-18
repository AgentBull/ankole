defmodule Ankole.Plugins.GitHubAdapter do
  @moduledoc "GitHub App and OAuth connections for repository collaboration."
  @behaviour Ankole.Plugins.Plugin
  def plugin_id, do: "github-adapter"
  def activation, do: :always
  def display_name, do: %{"default" => "GitHub"}

  def description,
    do: %{"default" => "Repository, issue, pull request, workflow, and release tools."}

  def adapter_declarations do
    [
      %{
        contract_id: "connectors.connector",
        id: "github",
        plugin_id: plugin_id(),
        module: Ankole.Plugins.GitHubAdapter.Connector,
        auth_schemes: ["github_app", "oauth2"],
        event_streams: [
          %{
            id: "github",
            label: "GitHub events",
            event_types:
              Enum.map(
                ~w(push create delete issues issue_comment pull_request pull_request_review pull_request_review_comment check_run check_suite release workflow_run workflow_job workflow_dispatch repository installation installation_repositories),
                &("github." <> &1)
              )
          }
        ],
        trigger_types: [
          %{
            id: "github_repository",
            label: "Repository",
            scope_label: "owner/repository",
            requires_personal_account: false
          },
          %{
            id: "github_organization",
            label: "Organization",
            scope_label: "Organization name",
            requires_personal_account: false
          }
        ],
        credential_fields: [
          %{
            key: "appID",
            label: "App ID",
            secret: false,
            required: true,
            schemes: ["github_app"]
          },
          %{
            key: "privateKey",
            label: text("App private key (PEM)", "App 私钥（PEM）", "App の秘密鍵（PEM）", "App 개인 키(PEM)"),
            type: "multiline",
            secret: true,
            required: true,
            schemes: ["github_app"]
          },
          %{
            key: "clientID",
            label: text("OAuth client ID", "OAuth 客户端 ID", "OAuth クライアント ID", "OAuth 클라이언트 ID"),
            secret: false,
            required: true,
            schemes: ["oauth2", "github_app"]
          },
          %{
            key: "clientSecret",
            label:
              text("OAuth client secret", "OAuth 客户端密钥", "OAuth クライアントシークレット", "OAuth 클라이언트 시크릿"),
            secret: true,
            required: true,
            schemes: ["oauth2", "github_app"]
          },
          %{
            key: "webhookSecret",
            label:
              text("App webhook secret", "App Webhook 密钥", "App の Webhook シークレット", "App 웹훅 시크릿"),
            secret: true,
            required: false,
            schemes: ["github_app"]
          }
        ],
        public_fields: [
          %{
            key: "installation_id",
            label:
              text(
                "GitHub App installation ID",
                "GitHub App 安装 ID",
                "GitHub App のインストール ID",
                "GitHub App 설치 ID"
              ),
            required: true,
            schemes: ["github_app"]
          },
          %{
            key: "base_url",
            label: text("REST API URL", "REST API 地址", "REST API の URL", "REST API URL"),
            required: false
          },
          %{
            key: "web_url",
            label:
              text("GitHub website URL", "GitHub 网站地址", "GitHub ウェブサイトの URL", "GitHub 웹사이트 URL"),
            required: false
          },
          %{
            key: "uploads_url",
            label:
              text("Release upload URL", "Release 上传地址", "Release アップロード URL", "Release 업로드 URL"),
            required: false
          }
        ]
      }
    ]
  end

  defp text(default, chinese, japanese, korean),
    do: %{"default" => default, "zh-Hans-CN" => chinese, "ja-JP" => japanese, "ko-KR" => korean}
end
