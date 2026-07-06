defmodule Ankole.AIGateway.ProviderConnectionCheck do
  @moduledoc """
  Prepared provider live-check request plus shared execution semantics.

  Provider modules own the endpoint, headers, and provider-specific auth rules.
  This module owns the common raw GET execution and upstream status-to-error
  shape used by operator-triggered connection checks.
  """

  alias Ankole.AIGateway.UniversalAIRequest

  @enforce_keys [:ctx, :path]
  defstruct [:ctx, :path, headers: nil]

  @type headers :: [{binary(), binary()}] | nil
  @type t :: %__MODULE__{ctx: map(), path: binary(), headers: headers()}

  @doc """
  Builds a prepared live-check request.
  """
  @spec get(map(), binary(), keyword()) :: {:ok, t()}
  def get(ctx, path, opts \\ []) when is_map(ctx) and is_binary(path) do
    {:ok, %__MODULE__{ctx: ctx, path: path, headers: Keyword.get(opts, :headers)}}
  end

  @doc """
  Executes a prepared provider live check through the native raw HTTP path.
  """
  @spec run(t()) :: {:ok, map()} | {:error, term()}
  def run(%__MODULE__{} = check) do
    with {:ok, %{"status" => status, "body" => body}} when status in 200..299 <-
           UniversalAIRequest.raw_get(check.ctx, check.path, raw_get_opts(check)) do
      {:ok, body}
    else
      {:ok, %{"status" => status, "body" => body}} ->
        {:error, {:provider_connection_check_failed, status, body}}

      {:error, _reason} = error ->
        error
    end
  end

  defp raw_get_opts(%__MODULE__{headers: nil}), do: []
  defp raw_get_opts(%__MODULE__{headers: headers}), do: [headers: headers]
end
