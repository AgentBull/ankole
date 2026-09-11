defmodule Ankole.Plugins.EmailAdapter.Config do
  @moduledoc "Validation and runtime helpers for the first-party Email adapter."

  import Ecto.Query, warn: false

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema
  alias Ankole.Plugins.EmailAdapter.Address
  alias Ankole.Plugins.MapHelpers
  alias Ankole.SignalsGateway.Binding

  @key_pattern ~r/\Asignals_gateway\.email\.bindings\.[A-Za-z0-9_.:-]+\z/
  @smtp_security_atoms %{"starttls" => :starttls, "tls" => :tls}
  @smtp_security Map.keys(@smtp_security_atoms)
  @sender_authentication_atoms %{"dmarc" => :dmarc, "none" => :none}
  @sender_authentication Map.keys(@sender_authentication_atoms)
  @ascii_credential ~r/\A[\x21-\x7E]+\z/

  @type t :: %{required(String.t()) => term()}

  defmodule Runtime do
    @moduledoc false

    @enforce_keys [
      :address,
      :imap_host,
      :imap_port,
      :smtp_host,
      :smtp_port,
      :smtp_security,
      :username,
      :password,
      :sender_authentication
    ]
    defstruct [
      :address,
      :display_name,
      :imap_host,
      :imap_port,
      :smtp_host,
      :smtp_port,
      :smtp_security,
      :username,
      :password,
      :sender_authentication
    ]

    @type t :: %__MODULE__{
            address: String.t(),
            display_name: String.t() | nil,
            imap_host: String.t(),
            imap_port: pos_integer(),
            smtp_host: String.t(),
            smtp_port: pos_integer(),
            smtp_security: :starttls | :tls,
            username: String.t(),
            password: String.t(),
            sender_authentication: :dmarc | :none
          }
  end

  @spec app_config_patterns() :: [Ankole.AppConfigure.PatternDefinition.t()]
  def app_config_patterns do
    [
      AppConfigure.define_pattern(
        id: "signals_gateway.email.bindings.*",
        key_pattern: @key_pattern,
        encrypted: true,
        schema: Schema.new(&validate_binding_config/1),
        description: "Encrypted email mailbox binding configuration."
      )
    ]
  end

  @spec fields() :: [map()]
  def fields do
    [
      text_field("address", true, %{"default" => "Mailbox address", "zh-Hans-CN" => "邮箱地址"}, %{
        "default" => "The address the Agent receives mail at and sends mail from.",
        "zh-Hans-CN" => "Agent 收发邮件使用的邮箱地址。"
      }),
      text_field("displayName", false, %{"default" => "Sender name", "zh-Hans-CN" => "发件人名称"}, %{
        "default" => "Optional display name for outgoing mail.",
        "zh-Hans-CN" => "外发邮件显示的发件人名称，可选。"
      }),
      text_field("imapHost", true, %{"default" => "IMAP host", "zh-Hans-CN" => "IMAP 主机"}, %{
        "default" => "IMAP server host. The connection uses implicit TLS.",
        "zh-Hans-CN" => "IMAP 服务器主机名，连接使用隐式 TLS。"
      }),
      integer_field("imapPort", 993, %{"default" => "IMAP port", "zh-Hans-CN" => "IMAP 端口"}),
      text_field("smtpHost", true, %{"default" => "SMTP host", "zh-Hans-CN" => "SMTP 主机"}, %{
        "default" => "SMTP submission server host.",
        "zh-Hans-CN" => "SMTP 发信服务器主机名。"
      }),
      integer_field("smtpPort", 587, %{"default" => "SMTP port", "zh-Hans-CN" => "SMTP 端口"}),
      %{
        path: "smtpSecurity",
        type: "select",
        required: true,
        encrypted: false,
        advanced: false,
        default: "starttls",
        label: %{"default" => "SMTP security", "zh-Hans-CN" => "SMTP 加密方式"},
        description: %{
          "default" => "STARTTLS on the submission port, or implicit TLS.",
          "zh-Hans-CN" => "在提交端口使用 STARTTLS，或使用隐式 TLS。"
        },
        options: [
          %{value: "starttls", label: %{"default" => "STARTTLS", "zh-Hans-CN" => "STARTTLS"}},
          %{value: "tls", label: %{"default" => "Implicit TLS", "zh-Hans-CN" => "隐式 TLS"}}
        ]
      },
      text_field("username", true, %{"default" => "Username", "zh-Hans-CN" => "用户名"}, %{
        "default" => "Login name for both IMAP and SMTP.",
        "zh-Hans-CN" => "IMAP 与 SMTP 共用的登录名。"
      }),
      %{
        path: "password",
        type: "secret",
        required: true,
        encrypted: true,
        advanced: false,
        label: %{"default" => "Password", "zh-Hans-CN" => "密码"},
        description: %{
          "default" =>
            "Mailbox password or app password. One mailbox can serve one enabled binding.",
          "zh-Hans-CN" => "邮箱密码或应用专用密码。一个邮箱只能用于一条已启用的路由规则。"
        }
      },
      %{
        path: "senderAuthentication",
        type: "select",
        required: true,
        encrypted: false,
        advanced: true,
        default: "dmarc",
        label: %{"default" => "Sender authentication", "zh-Hans-CN" => "发件人认证"},
        description: %{
          "default" =>
            "Require a DMARC pass from the receiving mail server before a sender is admitted, or trust the From header.",
          "zh-Hans-CN" => "要求收信服务器给出 DMARC 通过结果后才准入发件人，或直接信任 From 头。"
        },
        options: [
          %{
            value: "dmarc",
            label: %{"default" => "Require DMARC pass", "zh-Hans-CN" => "要求 DMARC 通过"}
          },
          %{
            value: "none",
            label: %{"default" => "Trust From header", "zh-Hans-CN" => "信任 From 头"}
          }
        ]
      }
    ]
  end

  @doc """
  Builds the stable AppConfigure key owned by one Agent binding.

  The digest gives each `(agent, binding)` pair its own key; a name-only key
  would collide across Agents that use the same binding name.
  """
  @spec binding_config_key(String.t(), String.t()) :: String.t()
  def binding_config_key(agent_uid, binding_name)
      when is_binary(agent_uid) and is_binary(binding_name) do
    id =
      [agent_uid, binding_name]
      |> Ankole.JSON.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "signals_gateway.email.bindings.#{id}"
  end

  @spec validate_binding_config(term()) :: {:ok, t()} | {:error, term()}
  def validate_binding_config(value) when is_map(value) do
    with {:ok, address} <- required_address(value, "address"),
         {:ok, display_name} <- MapHelpers.optional_string(value, "displayName", nil),
         {:ok, imap_host} <- required_host(value, "imapHost"),
         {:ok, imap_port} <- MapHelpers.integer_between(value, "imapPort", 993, 1, 65_535),
         {:ok, smtp_host} <- required_host(value, "smtpHost"),
         {:ok, smtp_port} <- MapHelpers.integer_between(value, "smtpPort", 587, 1, 65_535),
         {:ok, smtp_security} <- choice(value, "smtpSecurity", "starttls", @smtp_security),
         {:ok, username} <- required_credential(value, "username"),
         {:ok, password} <- required_credential(value, "password"),
         {:ok, sender_authentication} <-
           choice(value, "senderAuthentication", "dmarc", @sender_authentication) do
      {:ok,
       MapHelpers.compact_map(%{
         "address" => address,
         "displayName" => display_name,
         "imapHost" => imap_host,
         "imapPort" => imap_port,
         "smtpHost" => smtp_host,
         "smtpPort" => smtp_port,
         "smtpSecurity" => smtp_security,
         "username" => username,
         "password" => password,
         "senderAuthentication" => sender_authentication
       })}
    end
  end

  def validate_binding_config(_value), do: {:error, :invalid_email_binding_config}

  @doc """
  Rejects a mailbox that another enabled Email binding already owns.

  Two owners on one mailbox would race for the same unseen messages, and each
  would confirm mail that the other never saw.
  """
  @spec validate_binding_assignment(module(), String.t(), String.t(), t()) ::
          :ok | {:error, term()}
  def validate_binding_assignment(repo, agent_uid, binding_name, config)
      when is_atom(repo) and is_binary(agent_uid) and is_binary(binding_name) and is_map(config) do
    fingerprint = mailbox_fingerprint(config)

    Binding
    |> where(
      [binding],
      binding.adapter == "email" and binding.enabled == true and
        (binding.agent_uid != ^agent_uid or binding.name != ^binding_name)
    )
    |> repo.all()
    |> Enum.reduce_while(:ok, fn binding, :ok ->
      case load_config_ref_in_tx(repo, binding.config_ref) do
        {:ok, other} ->
          if mailbox_fingerprint(other) == fingerprint do
            {:halt, {:error, {:email_mailbox_already_bound, binding.agent_uid, binding.name}}}
          else
            {:cont, :ok}
          end

        :error ->
          {:halt, {:error, {:email_binding_config_unavailable, binding.agent_uid, binding.name}}}

        {:error, reason} ->
          {:halt,
           {:error, {:email_binding_config_unavailable, binding.agent_uid, binding.name, reason}}}
      end
    end)
  end

  @spec load_config_ref(String.t()) :: {:ok, Runtime.t()} | :error | {:error, term()}
  def load_config_ref(config_ref) when is_binary(config_ref) do
    with {:ok, key} <- app_config_key(config_ref),
         {:ok, value} <- AppConfigure.get_by_key(key),
         {:ok, config} <- validate_binding_config(value) do
      {:ok, runtime(config)}
    end
  end

  def load_config_ref(_config_ref), do: {:error, :invalid_config_ref}

  @spec runtime(t() | Runtime.t()) :: Runtime.t()
  def runtime(%Runtime{} = runtime), do: runtime

  def runtime(config) when is_map(config) do
    %Runtime{
      address: Map.fetch!(config, "address"),
      display_name: Map.get(config, "displayName"),
      imap_host: Map.fetch!(config, "imapHost"),
      imap_port: Map.get(config, "imapPort", 993),
      smtp_host: Map.fetch!(config, "smtpHost"),
      smtp_port: Map.get(config, "smtpPort", 587),
      smtp_security:
        Map.fetch!(@smtp_security_atoms, Map.get(config, "smtpSecurity", "starttls")),
      username: Map.fetch!(config, "username"),
      password: Map.fetch!(config, "password"),
      sender_authentication:
        Map.fetch!(@sender_authentication_atoms, Map.get(config, "senderAuthentication", "dmarc"))
    }
  end

  @doc "Fingerprint of every setting, so any change replaces the mailbox owner."
  @spec secret_fingerprint(t() | Runtime.t()) :: String.t()
  def secret_fingerprint(config) do
    runtime = runtime(config)

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(Map.from_struct(runtime)))
    |> Base.encode16(case: :lower)
  end

  @doc "Fingerprint of the mailbox identity that only one enabled binding may own."
  @spec mailbox_fingerprint(t() | Runtime.t()) :: String.t()
  def mailbox_fingerprint(config) do
    runtime = runtime(config)

    :sha256
    |> :crypto.hash([String.downcase(runtime.imap_host), 0, runtime.username])
    |> Base.encode16(case: :lower)
  end

  @doc """
  Transport options for the IMAP client.

  Tests override them through the `:imap_opts` application environment, for
  example to reach a plain TCP fake server.
  """
  @spec imap_options(Runtime.t()) :: keyword()
  def imap_options(%Runtime{} = runtime) do
    Keyword.merge(
      [host: runtime.imap_host, port: runtime.imap_port, transport: :ssl],
      env_opts(:imap_opts)
    )
  end

  @doc """
  `gen_smtp_client` options for the SMTP submission connection.

  Tests override them through the `:smtp_opts` application environment.
  """
  @spec smtp_options(Runtime.t()) :: keyword()
  def smtp_options(%Runtime{} = runtime) do
    host = String.to_charlist(runtime.smtp_host)

    # gen_smtp reads `sockopts` for an implicit TLS connection and
    # `tls_options` for a STARTTLS upgrade, so the certificate verification
    # options go to the entry that the selected mode uses.
    security =
      case runtime.smtp_security do
        :starttls -> [ssl: false, tls: :always, tls_options: tls_options(host)]
        :tls -> [ssl: true, tls: :never, sockopts: tls_options(host)]
      end

    Keyword.merge(
      [
        relay: host,
        port: runtime.smtp_port,
        username: String.to_charlist(runtime.username),
        password: String.to_charlist(runtime.password),
        auth: :always,
        no_mx_lookups: true,
        retries: 0,
        timeout: 60_000
      ] ++ security,
      env_opts(:smtp_opts)
    )
  end

  @spec tls_options(charlist()) :: keyword()
  def tls_options(host) when is_list(host) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: host,
      depth: 3,
      versions: [:"tlsv1.2", :"tlsv1.3"],
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp env_opts(key) do
    :ankole
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, [])
  end

  defp load_config_ref_in_tx(repo, config_ref) do
    with {:ok, key} <- app_config_key(config_ref),
         {:ok, value} <- AppConfigure.get_global_by_key_in_tx(repo, key) do
      validate_binding_config(value)
    end
  end

  defp app_config_key("app-config://" <> key), do: {:ok, key}
  defp app_config_key("app-config:" <> key), do: {:ok, key}
  defp app_config_key(key) when is_binary(key), do: {:ok, key}

  defp required_address(value, key) do
    with {:ok, raw} <- MapHelpers.required_string(value, key) do
      case Address.normalize(raw) do
        {:ok, address} -> {:ok, address}
        :error -> {:error, {:invalid_email_address, key}}
      end
    end
  end

  defp required_host(value, key) do
    with {:ok, host} <- MapHelpers.required_string(value, key) do
      if Regex.match?(~r/\A[A-Za-z0-9.-]+\z/, host),
        do: {:ok, String.downcase(host)},
        else: {:error, {:invalid_host, key}}
    end
  end

  defp required_credential(value, key) do
    with {:ok, credential} <- MapHelpers.required_string(value, key) do
      if Regex.match?(@ascii_credential, credential),
        do: {:ok, credential},
        else: {:error, {:invalid_credential, key}}
    end
  end

  defp choice(value, key, default, allowed) do
    with {:ok, choice} <- MapHelpers.optional_string(value, key, default) do
      if choice in allowed, do: {:ok, choice}, else: {:error, {:invalid_choice, key}}
    end
  end

  defp text_field(path, required, label, description) do
    %{
      path: path,
      type: "text",
      required: required,
      encrypted: false,
      advanced: false,
      label: label,
      description: description
    }
  end

  defp integer_field(path, default, label) do
    %{
      path: path,
      type: "integer",
      required: false,
      encrypted: false,
      advanced: false,
      default: default,
      label: label,
      description: %{"default" => "Default #{default}.", "zh-Hans-CN" => "默认 #{default}。"}
    }
  end
end

defimpl Inspect, for: Ankole.Plugins.EmailAdapter.Config.Runtime do
  import Inspect.Algebra

  def inspect(config, opts) do
    concat([
      "#Ankole.Plugins.EmailAdapter.Config.Runtime<",
      to_doc(
        %{address: config.address, imap_host: config.imap_host, password: "[REDACTED]"},
        opts
      ),
      ">"
    ])
  end
end
