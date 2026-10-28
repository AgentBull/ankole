defmodule Ankole.AgentWorkers.WorkerWebFetchConfig do
  @moduledoc """
  AppConfigure-backed policy for the private rendered `web_fetch` fallback.

  Interactive browser automation is a built-in BackgroundAgentJob capability,
  but it has an independent persistent route lifecycle. This setting controls
  only how long an unused ephemeral renderer may stay alive while a rendered
  fetch is being cleaned up.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Resolution
  alias Ankole.AppConfigure.Schema

  @rendered_fetch_idle_ttl_ms_key "agent_workers.rendered_fetch_idle_ttl_ms"
  @default_rendered_fetch_idle_ttl_ms 30 * 60 * 1_000
  @min_rendered_fetch_idle_ttl_ms 5 * 60 * 1_000
  @max_rendered_fetch_idle_ttl_ms 24 * 60 * 60 * 1_000

  @spec definition() :: Definition.t()
  def definition do
    AppConfigure.define(
      key: @rendered_fetch_idle_ttl_ms_key,
      scope: :tenant,
      encrypted: false,
      schema: schema(),
      default_value: @default_rendered_fetch_idle_ttl_ms,
      description:
        "Idle TTL in milliseconds before the private rendered web_fetch sidecar is released."
    )
  end

  @spec resolve(String.t()) :: {:ok, Resolution.t()} | {:error, term()} | :error
  def resolve(agent_uid) do
    AppConfigure.resolve(definition(), agent_id: agent_uid)
  end

  @doc "Builds the fetch policy shared by Job and environment execution."
  @spec runtime_config(String.t()) ::
          {:ok, Ankole.RuntimeFabric.V1.FetchRuntimeConfig.t()} | {:error, term()} | :error
  def runtime_config(agent_uid) do
    with {:ok, fetch} <- resolve(agent_uid),
         {:ok, ssrf?} <- Ankole.Security.SSRFFilter.enabled?(agent_uid) do
      {:ok,
       %Ankole.RuntimeFabric.V1.FetchRuntimeConfig{
         ssrf_filter: ssrf?,
         rendered_fetch_idle_ttl_ms: fetch.value
       }}
    end
  end

  defp schema do
    Schema.new(fn
      value
      when is_integer(value) and value >= @min_rendered_fetch_idle_ttl_ms and
             value <= @max_rendered_fetch_idle_ttl_ms ->
        {:ok, value}

      _value ->
        {:error,
         {:invalid_rendered_fetch_idle_ttl_ms,
          %{
            min: @min_rendered_fetch_idle_ttl_ms,
            max: @max_rendered_fetch_idle_ttl_ms
          }}}
    end)
  end
end
