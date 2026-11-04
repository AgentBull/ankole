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
            label: "App private key (PEM)",
            type: "multiline",
            secret: true,
            required: true,
            schemes: ["github_app"]
          },
          %{
            key: "clientID",
            label: "OAuth client ID",
            secret: false,
            required: true,
            schemes: ["oauth2", "github_app"]
          },
          %{
            key: "clientSecret",
            label: "OAuth client secret",
            secret: true,
            required: true,
            schemes: ["oauth2", "github_app"]
          },
          %{
            key: "webhookSecret",
            label: "App webhook secret",
            secret: true,
            required: false,
            schemes: ["github_app"]
          }
        ],
        public_fields: [
          %{
            key: "installation_id",
            label: "GitHub App installation ID",
            required: true,
            schemes: ["github_app"]
          },
          %{key: "base_url", label: "REST API URL", required: false},
          %{key: "web_url", label: "GitHub website URL", required: false},
          %{key: "uploads_url", label: "Release upload URL", required: false}
        ]
      }
    ]
  end
end
