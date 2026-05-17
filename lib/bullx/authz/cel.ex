defmodule BullX.AuthZ.CEL do
  @moduledoc """
  Elixir wrapper around CEL AuthZ NIFs exposed by `BullX.Ext`.

  Grants store CEL boolean expressions, not policy documents. Elixir and
  PostgreSQL match Principal, group, and action before this wrapper calls Rust.
  The Rust decision call owns resource-pattern matching and CEL evaluation for
  the already-loaded grants.
  """

  @nif_unavailable_reason "authz cel nif unavailable"

  defmodule Env do
    @moduledoc """
    Request environment passed to the AuthZ CEL decision NIF.
    """

    @enforce_keys [:principal, :action, :resource, :context]
    defstruct [:principal, :action, :resource, :context]

    @type t :: %__MODULE__{
            principal: %{
              required(String.t()) => Ecto.UUID.t() | String.t()
            },
            action: String.t(),
            resource: String.t(),
            context: %{required(String.t()) => map()}
          }
  end

  defmodule LoadedGrant do
    @moduledoc """
    Minimal loaded grant shape passed to the AuthZ CEL decision NIF.
    """

    @enforce_keys [:id, :resource_pattern, :condition]
    defstruct [:id, :resource_pattern, :condition]

    @type t :: %__MODULE__{
            id: Ecto.UUID.t(),
            resource_pattern: String.t(),
            condition: String.t()
          }
  end

  defmodule InvalidGrant do
    @moduledoc """
    Grant-level diagnostic returned by the AuthZ CEL decision NIF.
    """

    @enforce_keys [:id, :kind, :resource_pattern, :reason]
    defstruct [:id, :kind, :resource_pattern, :reason]

    @type kind ::
            :resource_pattern
            | :condition_compile
            | :condition_execution
            | :condition_result_type

    @type t :: %__MODULE__{
            id: Ecto.UUID.t(),
            kind: kind(),
            resource_pattern: String.t(),
            reason: term()
          }
  end

  @type invalid_kind :: InvalidGrant.kind()
  @type evaluation_result ::
          {:allow, [InvalidGrant.t()]}
          | {:deny, [InvalidGrant.t()]}
          | {:error, String.t()}

  @spec validate_condition(String.t()) :: :ok | {:error, String.t()}
  defdelegate validate_condition(condition), to: BullX.RuleEngine.CEL

  @spec evaluate_grants(Env.t(), [LoadedGrant.t()]) :: evaluation_result()
  def evaluate_grants(%Env{} = env, loaded_grants) when is_list(loaded_grants) do
    try do
      case BullX.Ext.authz_cel_eval_loaded_grants(env, loaded_grants) do
        {:allow, invalid_grants} when is_list(invalid_grants) ->
          {:allow, normalize_invalid_grants(invalid_grants)}

        {:deny, invalid_grants} when is_list(invalid_grants) ->
          {:deny, normalize_invalid_grants(invalid_grants)}

        {:error, reason} ->
          {:error, to_string(reason)}
      end
    rescue
      ErlangError -> {:error, @nif_unavailable_reason}
      UndefinedFunctionError -> {:error, @nif_unavailable_reason}
    catch
      :error, :nif_not_loaded -> {:error, @nif_unavailable_reason}
      kind, reason -> {:error, "cel #{kind}: #{inspect(reason)}"}
    end
  end

  def evaluate_grants(_env, _loaded_grants), do: {:error, "invalid cel evaluation input"}

  defp normalize_invalid_grants(invalid_grants) do
    Enum.map(invalid_grants, &normalize_invalid_grant/1)
  end

  defp normalize_invalid_grant(%InvalidGrant{} = invalid_grant), do: invalid_grant

  defp normalize_invalid_grant({id, kind, resource_pattern, reason}) do
    %InvalidGrant{
      id: id,
      kind: kind,
      resource_pattern: resource_pattern,
      reason: reason
    }
  end
end
