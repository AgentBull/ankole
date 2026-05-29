defmodule BullX.AuthZ.ResourcePattern do
  @moduledoc """
  Resource-pattern validation and matching for AuthZ permission grants.

  Persisted patterns use BullX resource globs backed by the Rust AuthZ rule
  engine. Caller request resources are validated separately and must not contain
  wildcards.
  """

  @spec validate(String.t()) :: :ok | {:error, String.t()}
  def validate(pattern) when is_binary(pattern) do
    case BullX.Ext.authz_resource_pattern_validate(pattern) do
      true -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(_pattern), do: {:error, "must be a string"}

  @spec match?(String.t(), String.t()) :: boolean()
  def match?(pattern, resource) when is_binary(pattern) and is_binary(resource) do
    loaded_grant = %BullX.AuthZ.CEL.LoadedGrant{
      id: "resource_pattern_match",
      resource_pattern: pattern,
      condition: "true"
    }

    env = %BullX.AuthZ.CEL.Env{
      principal: %{"uid" => "resource_pattern_match", "type" => "system", "status" => "active"},
      action: "match",
      resource: resource,
      context: %{}
    }

    case BullX.AuthZ.CEL.evaluate_grants(env, [loaded_grant]) do
      {:allow, _invalid_grants} -> true
      _other -> false
    end
  end

  def match?(_pattern, _resource), do: false
end
