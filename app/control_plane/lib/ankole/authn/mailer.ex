defmodule Ankole.Authn.Mailer do
  @moduledoc "SMTP transport for site login codes, separate from Agent email."

  @behaviour Ankole.Authn.Sender

  def configured? do
    case Ankole.Authn.Config.get("mail") do
      {:ok, settings} -> match?({:ok, _, _}, smtp_options(settings))
      _ -> false
    end
  end

  @impl true
  def send(:email, target, secret, opts),
    do: send_code(target, secret, Keyword.get(opts, :purpose, :login), opts)

  @subject "Ankole verification code"

  def send_code(email, code, _purpose, opts \\ []) do
    with {:ok, stored} <- Ankole.Authn.Config.get("mail"),
         settings = Keyword.get(opts, :mail, stored),
         {:ok, _options, from} <- smtp_options(settings) do
      text_body =
        "Your Ankole verification code is #{code}.\r\n" <>
          "Use it to verify your email address.\r\n" <>
          "If you did not request this code, ignore this email."

      case Application.get_env(:ankole, __MODULE__, [])[:adapter] || :smtp do
        :test ->
          Kernel.send(
            self(),
            {:delivered_email, %{to: email, from: from, subject: @subject, text_body: text_body}}
          )

          :ok

        :smtp ->
          deliver_smtp(settings, email, text_body)
      end
    end
  end

  def send_invitation(email, url, name) do
    with {:ok, settings} <- Ankole.Authn.Config.get("mail"),
         {:ok, _options, _from} <- smtp_options(settings) do
      text =
        "You are invited to join #{name} on Ankole.\r\nOpen #{url} to verify your identity and join."

      if Application.get_env(:ankole, __MODULE__, [])[:adapter] == :test do
        Kernel.send(
          self(),
          {:delivered_email, %{to: email, subject: "Ankole invitation", text_body: text}}
        )

        :ok
      else
        deliver_smtp(settings, email, text, "Ankole invitation")
      end
    end
  end

  defp deliver_smtp(settings, email, text_body, subject \\ @subject) do
    with {:ok, options, from} <- smtp_options(settings),
         body = encode_message(from, email, text_body, subject),
         {:ok, socket} <- :gen_smtp_client.open(options) do
      result = :gen_smtp_client.deliver(socket, {from, [email], body})
      close(socket)

      case result do
        {:ok, _receipt} -> :ok
        {:error, _reason} -> {:error, :mail_unavailable}
      end
    else
      _ -> {:error, :mail_unavailable}
    end
  end

  defp encode_message(from, to, text_body, subject) do
    :mimemail.encode(
      {"text", "plain",
       [
         {"From", from},
         {"To", to},
         {"Subject", subject},
         {"Auto-Submitted", "auto-generated"}
       ], %{content_type_params: [{"charset", "utf-8"}]}, text_body}
    )
  end

  defp smtp_options(%{"server" => server, "from" => from} = settings)
       when is_binary(server) and server != "" and is_binary(from) and from != "" do
    with {:ok, _} <- Ankole.Authn.Config.mail(settings) do
      host = String.to_charlist(server)
      tls_opts = tls_options(host, settings["cacertfile"])

      security =
        if settings["ssl"] == true do
          [ssl: true, tls: :never, sockopts: tls_opts]
        else
          [ssl: false, tls: :always, tls_options: tls_opts]
        end

      credentials =
        case {settings["username"], settings["password"]} do
          {username, password} when is_binary(username) and username != "" ->
            [
              auth: :always,
              username: String.to_charlist(username),
              password: String.to_charlist(password || "")
            ]

          _ ->
            [auth: :never]
        end

      {:ok,
       [
         relay: host,
         port: settings["port"] || 587,
         no_mx_lookups: true,
         retries: 0,
         timeout: 60_000
       ] ++ security ++ credentials, from}
    else
      _ -> {:error, :mail_unavailable}
    end
  end

  defp smtp_options(_settings), do: {:error, :mail_unavailable}

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

  defp close(socket) do
    :gen_smtp_client.close(socket)
  catch
    _kind, _reason -> :ok
  end
end
