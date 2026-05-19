defmodule BullX.EventBus.Scope do
  @moduledoc false

  alias BullX.EventBus.AppendFailed

  @fixed_paths MapSet.new([
                 "source",
                 "type",
                 "event.id",
                 "event.identity.source",
                 "event.identity.id",
                 "channel.adapter",
                 "channel.id",
                 "channel.kind",
                 "scope.id",
                 "scope.thread_id",
                 "actor.external_account_id",
                 "actor.principal.id",
                 "actor.principal.type",
                 "reply_channel.adapter",
                 "reply_channel.channel_id",
                 "reply_channel.scope_id",
                 "reply_channel.thread_id"
               ])

  @routing_fact_path ~r/\Arouting_facts\.[a-z][a-z0-9_]*\z/

  @spec valid_scope_field?(term()) :: boolean()
  def valid_scope_field?(field) when is_binary(field) do
    MapSet.member?(@fixed_paths, field) or Regex.match?(@routing_fact_path, field)
  end

  def valid_scope_field?(_field), do: false

  @spec scope_key(map(), [String.t()]) :: {:ok, String.t()} | {:error, AppendFailed.t()}
  def scope_key(context, fields) when is_list(fields) do
    fields
    |> Enum.reduce_while({:ok, []}, fn field, {:ok, acc} ->
      with true <- valid_scope_field?(field),
           {:ok, value} <- resolve_scalar(context, field) do
        {:cont, {:ok, [[field, value] | acc]}}
      else
        false -> {:halt, {:error, scope_error(field, "scope field is not allowed")}}
        {:error, reason} -> {:halt, {:error, scope_error(field, reason)}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Jason.encode!(Enum.reverse(pairs))}
      {:error, error} -> {:error, error}
    end
  end

  @spec window_key(map(), atom()) :: String.t()
  def window_key(context, :new_per_event) do
    source = get_in(context, ["event", "identity", "source"])
    id = get_in(context, ["event", "identity", "id"])
    Jason.encode!([["event.source", source], ["event.id", id]])
  end

  def window_key(_context, :rolling_ttl), do: "rolling"

  defp resolve_scalar(context, field) do
    value =
      field
      |> String.split(".")
      |> Enum.reduce_while(context, fn key, acc ->
        case acc do
          %{} -> resolve_map_key(acc, key)
          _value -> {:halt, :missing}
        end
      end)

    case value do
      :missing ->
        {:error, "scope path is missing"}

      value
      when is_binary(value) or is_boolean(value) or is_integer(value) or is_float(value) or
             is_nil(value) ->
        {:ok, value}

      _value ->
        {:error, "scope path must resolve to a scalar or null"}
    end
  end

  defp resolve_map_key(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:cont, value}
      :error -> {:halt, :missing}
    end
  end

  defp scope_error(field, reason) do
    %AppendFailed{
      code: :scope_resolution_failed,
      message: "scope resolution failed",
      details: %{"field" => field, "reason" => reason}
    }
  end
end
