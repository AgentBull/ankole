defmodule Ankole.Authn.Mailer do
  @moduledoc "Swoosh mailer for site login codes and Pod invitations, separate from Agent email."

  use Swoosh.Mailer, otp_app: :ankole

  @behaviour Ankole.Authn.Sender

  import Swoosh.Email,
    only: [new: 0, from: 2, to: 2, subject: 2, html_body: 2, text_body: 2, header: 3]

  alias Ankole.Authn.Emails.{InvitationTemplate, VerificationCodeTemplate}
  alias Ankole.I18n

  @default_local_from "noreply@ankole.localhost"
  @sender_name "Ankole"

  def configured? do
    case configured_adapter() do
      Swoosh.Adapters.Local ->
        true

      _ ->
        case Ankole.Authn.Config.get("mail") do
          {:ok, settings} -> match?({:ok, _, _}, smtp_delivery_config(settings))
          _ -> false
        end
    end
  end

  @impl true
  def send(:email, target, secret, opts),
    do: send_code(target, secret, Keyword.get(opts, :purpose, :login), opts)

  def send_code(email, code, _purpose, opts \\ []) do
    with {:ok, delivery_config, from_address, settings} <- resolve_transport(opts) do
      locale = resolve_locale(opts)
      minutes = code_ttl_minutes()
      subject_line = I18n.t("authn.email.code.subject", %{}, locale: locale)
      preview = I18n.t("authn.email.code.preview", %{code: code}, locale: locale)
      heading = I18n.t("authn.email.code.heading", %{}, locale: locale)
      intro = I18n.t("authn.email.code.intro", %{}, locale: locale)
      expires = I18n.t("authn.email.code.expires", %{minutes: minutes}, locale: locale)
      ignore = I18n.t("authn.email.code.ignore", %{}, locale: locale)
      footer = I18n.t("authn.email.footer", %{}, locale: locale)

      html =
        VerificationCodeTemplate.render(
          lang: locale,
          subject: subject_line,
          preview: preview,
          heading: heading,
          intro: intro,
          code: code,
          expires: expires,
          ignore: ignore,
          footer: footer
        )

      text =
        Enum.join(
          [
            heading,
            "",
            preview,
            "",
            intro,
            "",
            expires,
            ignore,
            "",
            "— #{@sender_name}"
          ],
          "\r\n"
        )

      message =
        new()
        |> from({@sender_name, from_address})
        |> to(email)
        |> subject(subject_line)
        |> html_body(html)
        |> text_body(text)
        |> header("Auto-Submitted", "auto-generated")

      deliver_message(message, delivery_config, settings)
    end
  end

  def send_invitation(email, url, name, opts \\ []) do
    with {:ok, delivery_config, from_address, settings} <- resolve_transport(opts) do
      locale = resolve_locale(opts)
      subject_line = I18n.t("authn.email.invitation.subject", %{name: name}, locale: locale)
      preview = I18n.t("authn.email.invitation.preview", %{name: name}, locale: locale)
      heading = I18n.t("authn.email.invitation.heading", %{name: name}, locale: locale)
      intro = I18n.t("authn.email.invitation.intro", %{name: name}, locale: locale)
      cta = I18n.t("authn.email.invitation.cta", %{}, locale: locale)
      fallback_label = I18n.t("authn.email.invitation.fallback_label", %{}, locale: locale)
      ignore = I18n.t("authn.email.invitation.ignore", %{}, locale: locale)
      footer = I18n.t("authn.email.footer", %{}, locale: locale)

      html =
        InvitationTemplate.render(
          lang: locale,
          subject: subject_line,
          preview: preview,
          heading: heading,
          intro: intro,
          url: url,
          cta: cta,
          fallback_label: fallback_label,
          ignore: ignore,
          footer: footer
        )

      text =
        Enum.join(
          [
            heading,
            "",
            intro,
            "",
            "#{cta}: #{url}",
            "",
            ignore,
            "",
            "— #{@sender_name}"
          ],
          "\r\n"
        )

      message =
        new()
        |> from({@sender_name, from_address})
        |> to(email)
        |> subject(subject_line)
        |> html_body(html)
        |> text_body(text)
        |> header("Auto-Submitted", "auto-generated")

      deliver_message(message, delivery_config, settings)
    end
  end

  defp deliver_message(message, delivery_config, settings) do
    case deliver(message, delivery_config) do
      {:ok, _receipt} -> :ok
      {:error, reason} -> delivery_failure(settings, reason)
    end
  end

  defp delivery_failure(settings, reason) do
    Ankole.Logging.warning("authn.mail_delivery_failed", "Login email delivery failed", %{
      server: settings && settings["server"],
      port: (settings && settings["port"]) || 587,
      reason: inspect(reason, limit: 20, printable_limit: 2000)
    })

    {:error, :mail_unavailable}
  end

  defp resolve_transport(opts) do
    adapter = configured_adapter()

    cond do
      Keyword.has_key?(opts, :mail) ->
        transport_from_settings(adapter, Keyword.get(opts, :mail))

      true ->
        case Ankole.Authn.Config.get("mail") do
          {:ok, nil} when adapter == Swoosh.Adapters.Local ->
            {:ok, [adapter: Swoosh.Adapters.Local], @default_local_from, nil}

          {:ok, %{} = stored} ->
            transport_from_settings(adapter, stored)

          _ ->
            {:error, :mail_unavailable}
        end
    end
  end

  defp transport_from_settings(adapter, settings) do
    with {:ok, smtp_config, from_address} <- smtp_delivery_config(settings) do
      config =
        case adapter do
          Swoosh.Adapters.SMTP -> [adapter: adapter] ++ smtp_config
          _ -> [adapter: adapter]
        end

      {:ok, config, from_address, settings}
    end
  end

  defp configured_adapter do
    Application.get_env(:ankole, __MODULE__, [])[:adapter] || Swoosh.Adapters.SMTP
  end

  defp smtp_delivery_config(%{"server" => server, "from" => from} = settings)
       when is_binary(server) and server != "" and is_binary(from) and from != "" do
    with {:ok, _} <- Ankole.Authn.Config.mail(settings) do
      tls_opts = tls_options(String.to_charlist(server), settings["cacertfile"])

      security =
        if settings["ssl"] == true do
          [ssl: true, tls: :never, sockopts: tls_opts]
        else
          [ssl: false, tls: :always, tls_options: tls_opts]
        end

      credentials =
        case {settings["username"], settings["password"]} do
          {username, password} when is_binary(username) and username != "" ->
            [auth: :always, username: username, password: password || ""]

          _ ->
            [auth: :never]
        end

      {:ok,
       [
         relay: server,
         port: settings["port"] || 587,
         no_mx_lookups: true,
         retries: 0,
         timeout: 60_000
       ] ++ security ++ credentials, from}
    else
      _ -> {:error, :mail_unavailable}
    end
  end

  defp smtp_delivery_config(_settings), do: {:error, :mail_unavailable}

  defp tls_options(host, cacertfile) do
    ca =
      if is_binary(cacertfile) and cacertfile != "" do
        [cacertfile: cacertfile]
      else
        [cacerts: :public_key.cacerts_get()]
      end

    [
      verify: :verify_peer,
      server_name_indication: host,
      depth: 3,
      versions: [:"tlsv1.2", :"tlsv1.3"],
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ] ++ ca
  end

  defp resolve_locale(opts) do
    I18n.negotiate_locale(Keyword.get(opts, :locale)) ||
      resolved_tenant_locale(opts) ||
      default_site_locale()
  end

  defp resolved_tenant_locale(opts) do
    case Keyword.fetch(opts, :tenant_id) do
      {:ok, tenant_id} -> tenant_locale(tenant_id)
      :error -> tenant_locale(Ankole.Repo.tenant_id())
    end
  end

  defp tenant_locale(tenant_id) when is_binary(tenant_id) do
    with {:ok, id} <- Ecto.UUID.cast(tenant_id),
         {:ok, locale} <- Ankole.Repo.with_tenant(id, &I18n.configured_default_locale/0) do
      locale
    else
      _ -> nil
    end
  end

  defp tenant_locale(_), do: nil

  defp default_site_locale do
    I18n.negotiate_locale(to_string(I18n.default_locale().requested_locale_id || "en-US")) ||
      "en-US"
  end

  defp code_ttl_minutes do
    case Ankole.Authn.Config.get("code_ttl_seconds") do
      {:ok, seconds} when is_integer(seconds) and seconds > 0 -> max(1, div(seconds + 59, 60))
      _ -> 10
    end
  end
end
