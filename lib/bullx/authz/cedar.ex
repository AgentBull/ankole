defmodule BullX.AuthZ.Cedar do
  @moduledoc """
  Elixir wrapper around Cedar condition NIFs exposed by `BullX.Ext`.

  Grants store Cedar boolean expressions, not complete policies. BullX matches
  subject, resource pattern, and action first; Cedar only evaluates the stored
  request-time condition.
  """

  alias BullX.AuthZ.Request
  alias BullX.Principals.Principal

  @principal_type "BullXPrincipal"
  @action_type "BullXAction"
  @resource_type "BullXResource"
  @nif_unavailable_reason "cedar nif unavailable"

  @type loaded_grant :: {String.t(), String.t(), String.t()}
  @type invalid_grant :: {String.t(), String.t()}

  @spec validate_condition(String.t()) :: :ok | {:error, String.t()}
  def validate_condition(condition) when is_binary(condition) do
    try do
      case BullX.Ext.cedar_condition_validate(condition) do
        true -> :ok
        {:error, reason} -> {:error, to_string(reason)}
      end
    rescue
      ErlangError -> {:error, @nif_unavailable_reason}
      UndefinedFunctionError -> {:error, @nif_unavailable_reason}
    catch
      :error, :nif_not_loaded -> {:error, @nif_unavailable_reason}
      kind, reason -> {:error, "cedar #{kind}: #{inspect(reason)}"}
    end
  end

  def validate_condition(_condition), do: {:error, "condition must be a string"}

  @spec evaluate(String.t(), Request.t()) :: {:ok, boolean()} | {:error, String.t()}
  def evaluate(condition, %Request{} = request) when is_binary(condition) do
    with {:ok, cedar_request} <- cedar_request(request) do
      try do
        case BullX.Ext.cedar_condition_eval(condition, cedar_request) do
          result when is_boolean(result) -> {:ok, result}
          {:error, reason} -> {:error, to_string(reason)}
        end
      rescue
        ErlangError -> {:error, @nif_unavailable_reason}
        UndefinedFunctionError -> {:error, @nif_unavailable_reason}
      catch
        :error, :nif_not_loaded -> {:error, @nif_unavailable_reason}
        kind, reason -> {:error, "cedar #{kind}: #{inspect(reason)}"}
      end
    end
  end

  @spec eval_loaded_grants(Request.t(), [loaded_grant()]) ::
          {:ok, boolean(), [invalid_grant()]} | {:error, String.t()}
  def eval_loaded_grants(%Request{} = request, loaded_grants) when is_list(loaded_grants) do
    with {:ok, cedar_request} <- cedar_request(request) do
      try do
        case BullX.Ext.authz_eval_loaded_grants(cedar_request, loaded_grants) do
          {:allow, invalid_grants} when is_list(invalid_grants) ->
            {:ok, true, invalid_grants}

          {:deny, invalid_grants} when is_list(invalid_grants) ->
            {:ok, false, invalid_grants}

          {:error, reason} ->
            {:error, to_string(reason)}
        end
      rescue
        ErlangError -> {:error, @nif_unavailable_reason}
        UndefinedFunctionError -> {:error, @nif_unavailable_reason}
      catch
        :error, :nif_not_loaded -> {:error, @nif_unavailable_reason}
        kind, reason -> {:error, "cedar #{kind}: #{inspect(reason)}"}
      end
    end
  end

  defp cedar_request(%Request{principal: %Principal{} = principal} = request) do
    {:ok,
     %{
       "principal" => %{
         "type" => @principal_type,
         "id" => principal.id,
         "attrs" => %{
           "id" => principal.id,
           "type" => Atom.to_string(principal.type),
           "status" => Atom.to_string(principal.status)
         }
       },
       "action" => %{
         "type" => @action_type,
         "id" => request.action
       },
       "resource" => %{
         "type" => @resource_type,
         "id" => request.resource
       },
       "context" => %{"request" => request.context}
     }}
  end

  defp cedar_request(%Request{}), do: {:error, "request principal missing"}
end
