defmodule Ankole.OIDC.Config do
  @moduledoc "The installation issuer, keys, and Principal policy for attesto."

  @allow_http_issuer Mix.env() in [:dev, :test]

  def issuer do
    Application.fetch_env!(:ankole, __MODULE__)
    |> Keyword.fetch!(:issuer)
    |> String.trim_trailing("/")
  end

  def get(audience \\ "ankole.oidc_userinfo", lifetime \\ 30 * 60) do
    issuer = issuer()

    options = [
      issuer: issuer,
      audience: audience,
      keystore: Ankole.OIDC.Keystore,
      principal_kind_claim: "subject_type",
      default_lifetime_seconds: lifetime,
      principal_kinds: [
        Attesto.PrincipalKind.new("human", :opaque,
          required_claims: [{"client_id", :non_empty_string}, {"sid", :non_empty_string}]
        ),
        Attesto.PrincipalKind.new("agent", :opaque)
      ]
    ]

    case URI.parse(issuer) do
      %URI{scheme: "https"} ->
        Attesto.Config.new(options)

      %URI{scheme: "http", host: host, query: nil, fragment: nil, userinfo: nil}
      when is_binary(host) and host != "" ->
        if @allow_http_issuer do
          :ok = Attesto.Keystore.validate!(Ankole.OIDC.Keystore)
          struct!(Attesto.Config, options)
        else
          raise ArgumentError, "HTTP OIDC issuers are restricted to development and tests"
        end

      _ ->
        raise ArgumentError, "invalid OIDC issuer"
    end
  end
end
