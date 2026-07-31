defmodule Ankole.Plugins.GoogleWorkspaceAdapter do
  @moduledoc "First-party Google Workspace identity (login + directory) plugin."

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.Plugins.GoogleWorkspaceAdapter.{Config, IdentityProvider}

  @zh_fields %{
    "clientID" =>
      {"OAuth 客户端 ID", "在 Google Cloud 控制台「Google Auth Platform → Clients」中创建 Web 应用后获取。"},
    "clientSecret" => {"OAuth 客户端密钥", "对应 OAuth Web 客户端的 Client Secret。"},
    "oidc.enabled" => {"启用登录", "允许管理员使用 Google Workspace 登录。"},
    "oidc.scopes" => {"登录权限范围", "登录时向 Google 请求的权限，通常无需修改。"},
    "oidc.allowedDomains" => {"允许登录的 Workspace 域名", "只有这些 Workspace 域名的账号可以登录，每行填写一个域名。"},
    "serviceAccountKey" => {"服务账号 JSON 密钥", "粘贴已配置全网域授权的服务账号完整 JSON 密钥。"},
    "adminEmail" => {"委派管理员邮箱", "服务账号通过全网域授权模拟此 Workspace 管理员读取用户和群组。"},
    "sync.contacts" => {"同步通讯录", "将 Google Workspace 用户和群组同步到 Ankole。"},
    "sync.pageSize" => {"每页同步数量", "每次从 Google Workspace 读取的记录数量，通常保留默认值。"},
    "sync.includeSuspended" => {"包含已停用用户", "同步时包含已停用和已归档的用户。"}
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
      field(
        "clientID",
        "OAuth client ID",
        "Create a Web application under Google Auth Platform > Clients.",
        :string,
        requiredWhen: [required_when("oidc.enabled", true)]
      ),
      field(
        "clientSecret",
        "OAuth client secret",
        "Client secret for the same OAuth web client.",
        :secret,
        encrypted: true,
        requiredWhen: [required_when("oidc.enabled", true)]
      ),
      field(
        "oidc.enabled",
        "Enable sign-in",
        "Allow administrators to sign in with Google Workspace.",
        :boolean,
        default: true
      ),
      field(
        "oidc.scopes",
        "Sign-in scopes",
        "Permissions requested during sign-in. Usually keep the default.",
        :string_array,
        default: ["openid", "email", "profile"],
        advanced: true
      ),
      field(
        "oidc.allowedDomains",
        "Allowed Workspace domains",
        "Only accounts in these Workspace domains can sign in. Enter one domain per line.",
        :string_array,
        requiredWhen: [required_when("oidc.enabled", true)],
        validation:
          pattern_validation(
            "^[A-Za-z0-9][A-Za-z0-9.-]*\\.[A-Za-z]{2,}$",
            "Enter a Workspace domain such as example.com on each line.",
            "请输入 Workspace 域名，例如 example.com，每行一个。"
          )
      ),
      field(
        "serviceAccountKey",
        "Service account JSON key",
        "Paste the full JSON key for a service account with domain-wide delegation.",
        :secret,
        encrypted: true,
        requiredWhen: [required_when("sync.contacts", true)],
        validation: %{
          kind: "json_object",
          requiredStringProperties: ["client_email", "private_key"],
          stringPrefixes: %{"private_key" => "-----BEGIN"},
          message: %{
            "default" =>
              "Paste a service account JSON key that contains client_email and private_key.",
            "zh-Hans-CN" => "请粘贴包含 client_email 和 private_key 的服务账号 JSON 密钥。"
          }
        }
      ),
      field(
        "adminEmail",
        "Delegated administrator email",
        "Workspace administrator that the service account impersonates to read users and groups.",
        :string,
        requiredWhen: [required_when("sync.contacts", true)],
        validation:
          pattern_validation(
            "^[^\\s@]+@[^\\s@]+$",
            "Enter a valid administrator email address.",
            "请输入有效的管理员邮箱地址。"
          )
      ),
      field(
        "sync.contacts",
        "Sync directory",
        "Import Google Workspace users and groups into Ankole.",
        :boolean,
        default: true
      ),
      field(
        "sync.pageSize",
        "Records per page",
        "Number of records requested from Google Workspace per page. Usually keep the default.",
        :integer,
        default: 500,
        min: 1,
        max: 500,
        advanced: true
      ),
      field(
        "sync.includeSuspended",
        "Include suspended users",
        "Include suspended and archived users in directory sync.",
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

  defp required_when(path, value), do: %{path: path, value: value}

  defp pattern_validation(pattern, message, zh_message) do
    %{
      kind: "pattern",
      pattern: pattern,
      message: %{"default" => message, "zh-Hans-CN" => zh_message}
    }
  end
end
