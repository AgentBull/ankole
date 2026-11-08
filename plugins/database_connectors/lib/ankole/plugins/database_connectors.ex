defmodule Ankole.Plugins.DatabaseConnectors do
  @moduledoc "Read-only PostgreSQL, MySQL, and ClickHouse connections as tenant-owned connectors."
  @behaviour Ankole.Plugins.Plugin
  alias Ankole.Plugins.DatabaseConnectors.{ClickHouse, Config, MySQL, Network, PostgreSQL}

  def plugin_id, do: "database-connectors"
  def activation, do: :always

  def display_name,
    do: l("Database connectors", "数据库连接器", "データベースコネクター", "데이터베이스 커넥터")

  def description,
    do: %{
      "default" =>
        "Read-only catalog search, value probes, plans, and guarded queries for PostgreSQL, MySQL, and ClickHouse."
    }

  def app_config_definitions, do: Config.definitions()

  def children,
    do: [{Task.Supervisor, name: Ankole.Plugins.DatabaseConnectors.Tasks}]

  def adapter_declarations do
    [
      declaration("postgresql", "PostgreSQL", PostgreSQL, 5432),
      declaration("mysql", "MySQL", MySQL, 3306),
      declaration("clickhouse", "ClickHouse", ClickHouse, 8443)
    ]
  end

  defp declaration(id, name, module, port) do
    %{
      contract_id: "connectors.connector",
      id: id,
      plugin_id: plugin_id(),
      module: module,
      display_name: %{"default" => name},
      auth_schemes: ["password"],
      public_fields: [
        field("host", l("Host", "主机", "ホスト", "호스트"), required: true),
        field("port", l("Port", "端口", "ポート", "포트"),
          type: "integer",
          default: port
        ),
        field("database", l("Database", "数据库", "データベース", "데이터베이스"), required: id == "postgresql"),
        field("tls_mode", l("TLS", "TLS 加密", "TLS 暗号化", "TLS 암호화"),
          type: "select",
          default: "verify",
          options:
            Enum.map(Network.tls_modes(), fn mode ->
              %{value: mode, label: tls_label(mode)}
            end)
        ),
        field(
          "ca_certificate",
          l(
            "CA certificate (PEM, optional)",
            "CA 证书（PEM，可选）",
            "CA 証明書（PEM、任意）",
            "CA 인증서(PEM, 선택)"
          ),
          type: "multiline"
        ),
        field(
          "sample_exclusions",
          l(
            "Columns excluded from value samples (column, table.column, or schema.table.column)",
            "不采集样本值的列（列名、表.列 或 模式.表.列）",
            "値のサンプルを取得しない列（列名、表.列、またはスキーマ.表.列）",
            "값 샘플을 수집하지 않을 열(열, 테이블.열 또는 스키마.테이블.열)"
          ),
          type: "string_array"
        )
      ],
      credential_fields: [
        field("username", l("Username", "用户名", "ユーザー名", "사용자 이름"),
          required: true,
          secret: false
        ),
        field("password", l("Password", "密码", "パスワード", "비밀번호"),
          required: true,
          secret: true
        )
      ]
    }
  end

  defp tls_label("verify"), do: l("Verify certificate", "校验证书", "証明書を検証", "인증서 검증")

  defp tls_label("require"),
    do: l("Encrypt without verification", "加密但不校验证书", "暗号化のみ（検証なし）", "암호화만(검증 안 함)")

  defp tls_label("disable"), do: l("Disabled", "不加密", "暗号化しない", "암호화 안 함")

  defp l(en, zh, ja, ko),
    do: %{"default" => en, "zh-Hans-CN" => zh, "ja-JP" => ja, "ko-KR" => ko}

  defp field(key, label, opts) do
    %{
      key: key,
      label: label,
      type: Keyword.get(opts, :type, "string"),
      required: Keyword.get(opts, :required, false),
      secret: Keyword.get(opts, :secret, false),
      default: Keyword.get(opts, :default),
      options: Keyword.get(opts, :options, [])
    }
  end
end
