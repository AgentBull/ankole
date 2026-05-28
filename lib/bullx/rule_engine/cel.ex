defmodule BullX.RuleEngine.CEL do
  @moduledoc """
  Shared CEL wrapper for BullX rule-engine surfaces.

  AuthZ and MailBox use different decision contracts, but they share CEL
  expression compilation and the same native rule-engine crate boundary.
  """

  @nif_unavailable_reason "rule-engine cel nif unavailable"

  @spec validate_condition(String.t()) :: :ok | {:error, String.t()}
  def validate_condition(condition) when is_binary(condition) do
    try do
      case BullX.Ext.rule_engine_cel_condition_validate(condition) do
        true -> :ok
        {:error, reason} -> {:error, to_string(reason)}
      end
    rescue
      ErlangError -> {:error, @nif_unavailable_reason}
      UndefinedFunctionError -> {:error, @nif_unavailable_reason}
    catch
      :error, :nif_not_loaded -> {:error, @nif_unavailable_reason}
      kind, reason -> {:error, "cel #{kind}: #{inspect(reason)}"}
    end
  end

  def validate_condition(_condition), do: {:error, "condition must be a string"}

  @doc """
  Encodes a binary as a CEL string literal.

  CEL string literals are JSON-compatible for the plain strings setup needs in
  routing expressions. Using the JSON encoder keeps operator-provided adapter
  and source ids out of hand-written CEL source.
  """
  @spec string_literal(String.t()) :: String.t()
  def string_literal(value) when is_binary(value), do: Jason.encode!(value)
end
