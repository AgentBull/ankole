defmodule Ankole.Plugins.GoogleWorkspaceAdapter do
  @moduledoc "First-party Google Workspace identity (login + directory) plugin."

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.Plugins.GoogleWorkspaceAdapter.{Config, IdentityProvider}

  @zh_fields %{
    "clientID" => {"Client ID", "Google Cloud OAuth 客户端 ID。"},
    "clientSecret" => {"Client Secret", "Google Cloud OAuth 客户端密码。"},
    "oidc.enabled" => {"启用 OIDC", "允许使用 Google 账号登录。"},
    "oidc.scopes" => {"OIDC 权限范围", "登录时请求的 scope。"},
    "oidc.allowedDomains" => {"允许的域名", "允许登录的 Workspace 域名列表；Google 无租户隔离，必须限定。"},
    "serviceAccountKey" => {"服务账号密钥", "启用域级委派的服务账号 JSON 密钥。"},
    "adminEmail" => {"管理员邮箱", "服务账号通过域级委派模拟的管理员账号。"},
    "sync.contacts" => {"同步目录", "导入 Google Workspace 用户与组。"},
    "sync.pageSize" => {"同步分页大小", "Directory API 列表接口的分页大小。"},
    "sync.includeSuspended" => {"包含停用用户", "目录同步是否包含已停用/已归档用户。"}
  }

  @impl true
  def plugin_id, do: "google-workspace-adapter"

  @impl true
  def display_name,
    do: %{"default" => "Google Workspace Adapter", "zh-Hans-CN" => "Google Workspace 适配器"}

  @impl true
  def description do
    %{
      "default" => "Connects Google Workspace as a login and directory provider.",
      "zh-Hans-CN" => "连接 Google Workspace 作为登录与目录提供方。"
    }
  end

  @impl true
  def app_config_patterns, do: Config.app_config_patterns()

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "principals.identity_provider",
        id: "google-workspace",
        plugin_id: plugin_id(),
        display_name: %{"default" => "Google Workspace", "zh-Hans-CN" => "Google Workspace"},
        config_key_pattern: "principals.identity_providers.google-workspace.<id>",
        fields: identity_fields(),
        module: IdentityProvider,
        # No directory_realtime_sync: the Google-side channel (Reports API
        # activities.watch, 6h channel TTL) is deliberately out of scope for
        # this phase; changes converge through periodic full sync.
        capabilities: [
          "oidc_authorization",
          "oidc_code_exchange",
          "directory_full_sync"
        ]
      }
    ]
  end

  defp identity_fields do
    [
      field("clientID", "Client ID", "Google Cloud OAuth client ID.", :string, []),
      field("clientSecret", "Client secret", "Google Cloud OAuth client secret.", :secret,
        encrypted: true
      ),
      field("oidc.enabled", "Enable OIDC", "Allow sign-in with Google.", :boolean, default: true),
      field("oidc.scopes", "OIDC scopes", "Scopes requested during login.", :string_array,
        default: ["openid", "email", "profile"],
        advanced: true
      ),
      field(
        "oidc.allowedDomains",
        "Allowed domains",
        "Workspace domains allowed to sign in; Google has no tenant isolation, so this list is required.",
        :string_array,
        []
      ),
      field(
        "serviceAccountKey",
        "Service account key",
        "JSON key of the service account with domain-wide delegation.",
        :secret,
        encrypted: true
      ),
      field(
        "adminEmail",
        "Admin email",
        "Administrator the service account impersonates through domain-wide delegation.",
        :string,
        []
      ),
      field(
        "sync.contacts",
        "Sync directory",
        "Import Google Workspace users and groups.",
        :boolean, default: true),
      field(
        "sync.pageSize",
        "Sync page size",
        "Directory API page size for list calls.",
        :integer,
        default: 500,
        min: 1,
        max: 500,
        advanced: true
      ),
      field(
        "sync.includeSuspended",
        "Include suspended users",
        "Whether directory sync includes suspended and archived users.",
        :boolean,
        default: false,
        advanced: true
      )
    ]
  end

  defp field(path, label, description, type, opts) do
    {zh_label, zh_description} = Map.fetch!(@zh_fields, path)

    opts
    |> Map.new()
    |> Map.put_new(:advanced, false)
    |> Map.merge(%{
      path: path,
      label: %{"default" => label, "zh-Hans-CN" => zh_label},
      description: %{"default" => description, "zh-Hans-CN" => zh_description},
      type: Atom.to_string(type)
    })
  end
end
