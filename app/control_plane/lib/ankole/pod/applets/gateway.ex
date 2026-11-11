defmodule Ankole.Pod.Applets.Gateway do
  @moduledoc "Shared principal resolution, usage attribution, and error projection for Applet AI and Web capabilities."

  alias Ankole.AIGateway.{OpenAIError, ProviderFailure}
  alias Ankole.AuthZ.Actor
  alias Ankole.Pod.Access

  @type domain :: :ai | :ai_image | :web_search | :web_fetch

  @doc "Resolves the effective Applet execution principal inside the caller's turn authority."
  def with_principal(%Actor{} = actor, fun) when is_function(fun, 1) do
    with {:ok, principal} <- Access.write(actor.turn_authority, fn -> Access.principal(actor) end) do
      fun.(principal)
    end
  end

  @doc "Attributes Applet usage to the invoking Human when the execution principal is a Human."
  def human_context(%{type: :human, uid: uid}), do: %{"human_uid" => uid}
  def human_context(_principal), do: %{}

  @doc "Invokes an AIGateway capability under `caller: \"pod_applet\"` and maps failures into Applet HTTP error envelopes."
  def call(principal, domain, create, request, extra_opts \\ [])
      when domain in [:ai, :ai_image, :web_search, :web_fetch] and is_function(create, 3) do
    opts =
      Keyword.merge(
        [caller: "pod_applet", request_context: human_context(principal)],
        extra_opts
      )

    case create.(principal.uid, request, opts) do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, reason} -> {:error, error(domain, reason)}
    end
  end

  @doc "Projects an internal or gateway error reason into the public Applet error envelope."
  def error(_domain, %OpenAIError{code: "request_too_large", message: message}),
    do: envelope(413, "file_too_large", message)

  def error(_domain, %OpenAIError{status: 413, message: message}),
    do: envelope(413, "file_too_large", message)

  def error(_domain, %OpenAIError{
        type: "image_generation_user_error",
        code: code,
        message: message
      }),
      do: envelope(422, code || "invalid_request", message)

  def error(_domain, %OpenAIError{status: 400, message: message}),
    do: envelope(400, "invalid_request", message)

  def error(:ai_image, %OpenAIError{status: 422, code: "unsupported_value", message: message}),
    do: envelope(422, "unsupported_value", message)

  def error(:ai_image, %OpenAIError{status: 422, message: message}),
    do: envelope(400, "invalid_request", message)

  def error(domain, %OpenAIError{status: 422, code: code, message: message}),
    do: envelope(422, code || not_configured_code(domain), message)

  def error(domain, %OpenAIError{message: message}),
    do: envelope(502, unavailable_code(domain), message)

  def error(_domain, {:agent_token_quota_exceeded, _}),
    do: envelope(429, "agent_token_quota_exceeded")

  def error(_domain, {:reasoning_effort, _}),
    do: envelope(422, "invalid_effort")

  def error(
        _domain,
        %ProviderFailure{
          provider_status: status,
          provider_body: %{"error" => %{"param" => param}}
        }
      )
      when status in [400, 422] and
             param in ["reasoning.effort", "reasoning_effort", "reasoningEffort"],
      do: envelope(422, "invalid_effort")

  def error(_domain, reason)
      when reason in [
             :invalid_request,
             :invalid_request_body,
             :missing_query,
             :invalid_query,
             :invalid_limit,
             :missing_urls,
             :invalid_urls
           ],
      do: envelope(400, "invalid_request")

  def error(domain, reason)
      when reason in [
             :ai_not_configured,
             :model_profile_not_configured,
             :system_principal_missing
           ],
      do: envelope(422, not_configured_code(domain))

  def error(domain, :invalid_model),
    do: envelope(422, invalid_model_code(domain))

  def error(domain, :invalid_model_profile),
    do: envelope(422, invalid_model_code(domain))

  def error(domain, {name, _})
      when name in [
             :unknown_model_selector,
             :invalid_model_profile,
             :model_profile_capability_mismatch
           ],
      do: envelope(422, invalid_model_code(domain))

  def error(domain, _reason),
    do: envelope(502, unavailable_code(domain))

  defp not_configured_code(:web_search), do: "web_search_not_configured"
  defp not_configured_code(:web_fetch), do: "web_fetch_not_configured"
  defp not_configured_code(_ai), do: "ai_not_configured"

  defp invalid_model_code(:web_search), do: "web_search_not_configured"
  defp invalid_model_code(:web_fetch), do: "web_fetch_not_configured"
  defp invalid_model_code(_ai), do: "invalid_model"

  defp unavailable_code(:web_search), do: "web_search_unavailable"
  defp unavailable_code(:web_fetch), do: "web_fetch_unavailable"
  defp unavailable_code(_ai), do: "ai_unavailable"

  defp envelope(status, code, message \\ nil) do
    %{status: status, code: code, message: message || code, details: nil}
  end
end
