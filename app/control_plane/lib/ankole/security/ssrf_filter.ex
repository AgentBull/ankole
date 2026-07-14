defmodule Ankole.Security.SSRFFilter do
  @moduledoc """
  AppConfigure-backed SSRF filtering for model-controlled URL fetches.

  `security.ssrf_filter` defaults to `false` because Ankole is commonly used as
  an enterprise-internal agent and intranet access is expected. When enabled,
  private, loopback, link-local, and CGNAT targets are rejected. Cloud metadata
  endpoints remain blocked regardless of the setting.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema

  @key "security.ssrf_filter"

  @spec definition() :: Definition.t()
  def definition do
    AppConfigure.define(
      key: @key,
      scope: :scoped,
      encrypted: false,
      schema: Schema.boolean(),
      default_value: false,
      description:
        "When true, model-controlled URL fetches reject private, loopback, link-local, and CGNAT hosts. Cloud metadata endpoints are always rejected."
    )
  end

  @spec ensure_registered() :: :ok | {:error, term()}
  def ensure_registered do
    case AppConfigure.register_definitions([definition()]) do
      :ok -> :ok
      {:error, {:duplicate_key, @key}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec enabled?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def enabled?(agent_uid) when is_binary(agent_uid) do
    with :ok <- ensure_registered(),
         {:ok, resolution} <- AppConfigure.resolve(definition(), agent_id: agent_uid) do
      {:ok, resolution.value == true}
    else
      :error -> {:error, :ssrf_filter_unresolved}
      {:error, reason} -> {:error, reason}
    end
  end
end
