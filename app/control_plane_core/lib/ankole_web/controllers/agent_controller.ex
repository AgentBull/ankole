defmodule AnkoleWeb.AgentController do
  alias Ankole.Attrs
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for the model profiles, the provider-hosted capabilities,
  and the token quota of an agent. The agent records are in the v2 API
  (`Ankole.Principals.Agent`).
  """

  use AnkoleWeb, :controller

  action_fallback :fallback
  use OpenAPISpex.ControllerSpecs

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIAgent.TokenQuota
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsoleParams
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.ModelProfileResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ModelProfileWriteRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.ModelProfilesResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ProviderHostedResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ProviderHostedWriteRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.TokenQuotaResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.TokenQuotaWriteRequest

  tags(["Agents"])
  security([%{"consoleSession" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index_model_profiles,
    summary: "Read all model profiles for one agent",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Model profiles", "application/json", ModelProfilesResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:put_provider_hosted,
    summary: "Set which capabilities an agent leaves to its language-model provider",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    request_body:
      {"Provider hosted capabilities", "application/json", ProviderHostedWriteRequest,
       required: true},
    responses: [
      ok: {"Provider hosted capabilities", "application/json", ProviderHostedResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:put_model_profile,
    summary: "Create or update one model profile for an agent",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      profile: [in: :path, type: :string, required: true]
    ],
    request_body: {"Model profile", "application/json", ModelProfileWriteRequest, required: true},
    responses: [
      ok: {"Model profile", "application/json", ModelProfileResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete_model_profile,
    summary: "Clear one optional model profile for an agent",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      profile: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok: {"Model profile", "application/json", ModelProfileResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:show_token_quota,
    summary: "Read the token quota and the current window of one agent",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Token quota", "application/json", TokenQuotaResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:put_token_quota,
    summary: "Set the token quota of one agent",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    request_body: {"Token quota", "application/json", TokenQuotaWriteRequest, required: true},
    responses: [
      ok: {"Token quota", "application/json", TokenQuotaResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete_token_quota,
    summary: "Remove the token quota of one agent, which leaves it without a limit",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Token quota", "application/json", TokenQuotaResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:reset_token_quota,
    summary: "Start a new token quota period at this instant",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Token quota", "application/json", TokenQuotaResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  def index_model_profiles(conn, params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:model_profiles", "read"),
         {:ok, profiles} <- ModelProfiles.get_model_profiles(agent_uid) do
      json(conn, %{
        model_profiles: profiles,
        provider_hosted: provider_hosted_payload(agent_uid)
      })
    end
  end

  def put_provider_hosted(conn, params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:model_profiles", "update"),
         {:ok, capabilities} <-
           ModelProfiles.put_provider_hosted_capabilities(agent_uid, conn.body_params) do
      json(conn, %{provider_hosted: normalized_provider_hosted(capabilities)})
    end
  end

  defp provider_hosted_payload(agent_uid) do
    case ModelProfiles.provider_hosted_capabilities(agent_uid) do
      {:ok, capabilities} -> normalized_provider_hosted(capabilities)
      {:error, _reason} -> normalized_provider_hosted(%{})
    end
  end

  # Always answer with every capability so a client never has to know the
  # default. An unset capability belongs to the Provider.
  defp normalized_provider_hosted(capabilities) do
    %{
      web_search: ModelProfiles.provider_hosted?(capabilities, "web_search"),
      image_generate: ModelProfiles.provider_hosted?(capabilities, "image_generate")
    }
  end

  def put_model_profile(conn, params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid),
         {:ok, profile} <- profile_param(params),
         :ok <-
           ConsolePolicy.authorize(conn, "agent:#{agent_uid}:model_profile:#{profile}", "update"),
         {:ok, %{profile: profile_attrs}} <-
           ModelProfiles.put_model_profile(agent_uid, profile, conn.body_params) do
      json(conn, %{model_profile: model_profile_payload(profile, profile_attrs)})
    end
  end

  def delete_model_profile(conn, params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid),
         {:ok, profile} <- profile_param(params),
         :ok <-
           ConsolePolicy.authorize(conn, "agent:#{agent_uid}:model_profile:#{profile}", "delete"),
         {:ok, %{profile: profile_attrs}} <-
           ModelProfiles.put_model_profile(agent_uid, profile, nil) do
      json(conn, %{model_profile: model_profile_payload(profile, profile_attrs)})
    end
  end

  def show_token_quota(conn, params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:token_quota", "read"),
         {:ok, status} <- TokenQuota.status(agent_uid) do
      json(conn, token_quota_payload(status))
    end
  end

  def put_token_quota(conn, params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:token_quota", "update"),
         {:ok, _quota} <- TokenQuota.put(agent_uid, conn.body_params),
         {:ok, status} <- TokenQuota.status(agent_uid) do
      json(conn, token_quota_payload(status))
    end
  end

  def delete_token_quota(conn, params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:token_quota", "delete"),
         {:ok, nil} <- TokenQuota.delete(agent_uid),
         {:ok, status} <- TokenQuota.status(agent_uid) do
      json(conn, token_quota_payload(status))
    end
  end

  def reset_token_quota(conn, params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:token_quota", "update"),
         {:ok, _quota} <- TokenQuota.reset(agent_uid),
         {:ok, status} <- TokenQuota.status(agent_uid) do
      json(conn, token_quota_payload(status))
    end
  end

  defp token_quota_payload(%{token_quota: token_quota, usage: usage}) do
    %{token_quota: token_quota, usage: token_quota_usage_payload(usage)}
  end

  defp token_quota_usage_payload(nil), do: nil

  defp token_quota_usage_payload(window) do
    %{
      window_started_at: DateTime.to_iso8601(window.window_started_at),
      window_ends_at: DateTime.to_iso8601(window.window_ends_at),
      used_tokens: window.used_tokens,
      exceeded: window.exceeded
    }
  end

  defp profile_param(params) do
    case Map.get(params, :profile) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing, "profile"}}
    end
  end

  defp model_profile_payload(profile, nil), do: %{"profile" => profile, "configured" => false}

  defp model_profile_payload(profile, attrs) do
    attrs
    |> Attrs.normalize_external_attrs()
    |> Map.put("profile", profile)
    |> Map.put("configured", true)
  end

  defp fallback(conn, failure), do: ConsoleErrors.fallback(conn, failure, &error/2)

  defp error(conn, :not_found), do: ConsoleErrors.not_found(conn, "agent was not found")
  defp error(conn, :not_agent), do: ConsoleErrors.not_found(conn, "agent was not found")

  defp error(conn, :image_model_unavailable) do
    ConsoleErrors.render(
      conn,
      422,
      "image_model_unavailable",
      "selected image model has no usable image-generation endpoint"
    )
  end

  defp error(conn, :image_model_catalog_unavailable) do
    ConsoleErrors.render(
      conn,
      422,
      "image_model_catalog_unavailable",
      "image model availability could not be verified; try again later"
    )
  end

  defp error(conn, :invalid_period_days),
    do:
      ConsoleErrors.render(
        conn,
        422,
        "validation_failed",
        "period_days must be an integer of at least 1"
      )

  defp error(conn, :invalid_period_start_at),
    do:
      ConsoleErrors.render(
        conn,
        422,
        "validation_failed",
        "period_start_at must be an ISO 8601 instant"
      )

  defp error(conn, :invalid_limit_tokens),
    do:
      ConsoleErrors.render(
        conn,
        422,
        "validation_failed",
        "limit_tokens must be an integer of at least 1"
      )

  defp error(conn, :token_quota_not_configured),
    do:
      ConsoleErrors.render(
        conn,
        422,
        "token_quota_not_configured",
        "agent has no token quota to reset"
      )

  defp error(conn, {:missing, key}) do
    ConsoleErrors.required_field(conn, key)
  end

  defp error(conn, reason) do
    ConsoleErrors.unexpected(
      conn,
      "ai_agent.agent_api.unexpected_error",
      reason,
      "invalid_agent",
      "agent configuration is invalid"
    )
  end
end
