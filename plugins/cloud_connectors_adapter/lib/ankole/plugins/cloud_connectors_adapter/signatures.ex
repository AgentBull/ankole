defmodule Ankole.Plugins.CloudConnectorsAdapter.Signatures do
  @moduledoc false

  def verify("gitlab", secret, body, headers, _config),
    do: verified(secret, header(headers, "x-gitlab-token"), body)

  def verify("typeform", secret, body, headers, _config),
    do:
      verified(
        "sha256=" <> mac(:sha256, secret, body, :base64),
        header(headers, "typeform-signature"),
        body
      )

  def verify("trello", secret, body, headers, config),
    do:
      verified(
        mac(:sha, secret, body <> (config["callback_url"] || ""), :base64),
        header(headers, "x-trello-webhook"),
        body
      )

  def verify(id, secret, body, headers, _config) when id in ~w(stripe calendly) do
    name = if id == "stripe", do: "stripe-signature", else: "calendly-webhook-signature"

    parts =
      String.split(header(headers, name) || "", ",") |> Enum.map(&String.split(&1, "=", parts: 2))

    timestamp =
      Enum.find_value(parts, fn
        [key, value] -> if key == "t", do: value
        _ -> nil
      end)

    signatures = for ["v1", value] <- parts, do: value

    with {seconds, ""} <- Integer.parse(timestamp || ""),
         true <- abs(System.system_time(:second) - seconds) <= 300,
         expected <- mac(:sha256, secret, timestamp <> "." <> body, :hex),
         true <- Enum.any?(signatures, &same?(expected, &1)) do
      Torque.decode(body)
    else
      _ -> {:error, :invalid_webhook_signature}
    end
  end

  def verify("zendesk", secret, body, headers, _config) do
    timestamp = header(headers, "x-zendesk-webhook-signature-timestamp") || ""

    verified(
      mac(:sha256, secret, timestamp <> body, :base64),
      header(headers, "x-zendesk-webhook-signature"),
      body
    )
  end

  def verify("sentry", secret, body, headers, _config),
    do: verified(mac(:sha256, secret, body, :hex), header(headers, "sentry-hook-signature"), body)

  def verify("figma", secret, body, _headers, _config) do
    with {:ok, payload} <- Torque.decode(body),
         true <- same?(secret, payload["passcode"]) do
      {:ok, Map.delete(payload, "passcode")}
    else
      _ -> {:error, :invalid_webhook_signature}
    end
  end

  defp verified(expected, actual, body) do
    if same?(expected, actual),
      do: Torque.decode(body),
      else: {:error, :invalid_webhook_signature}
  end

  defp same?(left, right) when is_binary(left) and is_binary(right),
    do: left != "" and Plug.Crypto.secure_compare(left, right)

  defp same?(_, _), do: false
  defp mac(_, nil, _, _), do: ""

  defp mac(hash, secret, body, :hex),
    do: Base.encode16(:crypto.mac(:hmac, hash, secret, body), case: :lower)

  defp mac(hash, secret, body, :base64), do: Base.encode64(:crypto.mac(:hmac, hash, secret, body))

  def header(headers, name),
    do:
      Enum.find_value(headers, fn {key, value} -> if String.downcase(key) == name, do: value end)
end
