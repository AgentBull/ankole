defmodule Ankole.AIGateway.ProviderConfigs.Console.Actions do
  @moduledoc "Runs the Console sign-in actions through the provider credential domain."
  use Ash.Resource.Actions.Implementation

  alias Ankole.AIGateway.ChatGPTAuth
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.Errors.Invalid.{NotFound, Rejected}

  @impl true
  def run(input, _opts, _context) do
    input.action.name
    |> action(input.arguments)
    |> Ankole.Errors.wrap(&rejection/1)
  end

  defp action(:models, _args), do: {:ok, %{models: Ankole.AIGateway.Models.console_catalog()}}

  defp action(:provider_kinds, _args),
    do: {:ok, %{provider_kinds: ProviderConfigs.list_provider_kinds()}}

  defp action(:start, args),
    do: ChatGPTAuth.start_login(args.provider_id, Map.take(args, [:id, :label, :priority]))

  defp action(:poll, args), do: ChatGPTAuth.poll_login(args.provider_id, args.login_context)

  defp action(:complete, args),
    do:
      ChatGPTAuth.complete_browser_login(args.provider_id, args.login_context, args.callback_url)

  defp action(:enterprise, args) do
    with {:ok, provider} <-
           ChatGPTAuth.add_enterprise_credential(args.provider_id, args.credential) do
      {:ok, %{ai_gateway_provider: ProviderConfigs.projection(provider)}}
    end
  end

  defp rejection(:not_found), do: NotFound.exception(resource: ProviderConfigs.Provider)

  defp rejection(:credential_not_found),
    do: NotFound.exception(resource: ProviderConfigs.Provider)

  defp rejection({kind, status, code})
       when kind in [:device_login_failed, :token_exchange_failed] do
    rejected(
      :chatgpt_login_rejected,
      "ChatGPT sign-in was rejected by the sign-in service (#{upstream_label(status, code)})",
      [%{upstream_status: status, upstream_code: code}]
    )
  end

  defp rejection(:invalid_device_login_response),
    do:
      rejected(
        :chatgpt_login_rejected,
        "the ChatGPT sign-in service returned an unexpected device-login response"
      )

  defp rejection({:request_failed, reason}) do
    label =
      if is_atom(reason) or is_binary(reason), do: to_string(reason), else: "transport_error"

    rejected(
      :chatgpt_login_unreachable,
      "the ChatGPT sign-in service was unreachable (#{label})",
      [%{transport: label}]
    )
  end

  defp rejection({:oauth_denied, code}),
    do:
      rejected(:chatgpt_login_denied, "the ChatGPT account denied the sign-in request", [
        %{upstream_code: code}
      ])

  defp rejection(:login_expired),
    do: rejected(:chatgpt_login_expired, "the ChatGPT sign-in expired; start it again")

  defp rejection(:oauth_state_mismatch),
    do:
      rejected(
        :chatgpt_login_invalid,
        "the pasted callback URL belongs to a different sign-in attempt"
      )

  defp rejection(:invalid_device_pkce),
    do: rejected(:chatgpt_login_invalid, "the device sign-in context failed verification")

  defp rejection(:invalid_callback_url), do: {"callback_url is not a valid URL", []}

  defp rejection(reason) when reason in [:invalid_login_context, :invalid_device_poll_interval],
    do: {"login_context is invalid; start the sign-in again", []}

  defp rejection(:provider_not_chatgpt_subscription),
    do: {"this provider is not a ChatGPT subscription provider", []}

  defp rejection(:login_issuer_changed),
    do:
      rejected(
        :chatgpt_login_invalid,
        "the provider's sign-in issuer changed; start the sign-in again"
      )

  defp rejection(reason) when reason in [:invalid_jwt, :invalid_jwt_expiration],
    do: rejected(:chatgpt_login_rejected, "the ChatGPT sign-in service returned an invalid token")

  defp rejection({:missing, field}),
    do: {"#{field} is required", [%{path: field, message: "is required"}]}

  defp rejection(reason), do: ProviderConfigs.rejection(reason)

  defp rejected(code, message, details \\ []),
    do: Rejected.exception(reason: code, detail: message, details: details)

  defp upstream_label(nil, code), do: "#{code || "unknown error"}"
  defp upstream_label(status, nil), do: "HTTP #{status}"
  defp upstream_label(status, code), do: "HTTP #{status}, #{code}"
end
