defmodule Ankole.Schedule.Delivery do
  @moduledoc false

  alias Ankole.Schedule.Attrs

  @type target :: %{required(String.t()) => String.t()}

  @spec normalize(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def normalize(delivery, binding_name) when is_map(delivery) and is_binary(binding_name) do
    with {:ok, targets} <- normalize_targets(delivery),
         :ok <- validate_primary_binding(targets, binding_name),
         :ok <- validate_unique_targets(targets),
         {:ok, quiet_success} <- normalize_quiet_success(delivery) do
      normalized = %{"targets" => targets}

      {:ok,
       case quiet_success do
         :unset -> normalized
         value -> Map.put(normalized, "quiet_success", value)
       end}
    end
  end

  def normalize(_delivery, _binding_name), do: {:error, :cron_delivery_route_required}

  @spec merge_update(term(), term(), String.t()) :: {:ok, map()} | {:error, term()}
  def merge_update(existing, update, binding_name)
      when is_map(update) and is_binary(binding_name) do
    if route_update?(update) do
      with {:ok, normalized_update} <- normalize(update, binding_name) do
        preserve_existing_quiet_success(existing, normalized_update)
      end
    else
      with {:ok, existing} <- normalize(existing, binding_name),
           {:ok, quiet_success} <- normalize_quiet_success(update) do
        case quiet_success do
          :unset -> {:error, :cron_delivery_update_required}
          value -> {:ok, Map.put(existing, "quiet_success", value)}
        end
      end
    end
  end

  def merge_update(_existing, _update, _binding_name),
    do: {:error, :cron_delivery_route_required}

  @spec targets(term(), String.t()) :: {:ok, [target()]} | {:error, term()}
  def targets(delivery, binding_name) do
    with {:ok, normalized} <- normalize(delivery, binding_name) do
      {:ok, normalized["targets"]}
    end
  end

  @spec primary_target(term(), String.t()) :: {:ok, target()} | {:error, term()}
  def primary_target(delivery, binding_name) do
    with {:ok, [target | _rest]} <- targets(delivery, binding_name) do
      {:ok, target}
    end
  end

  @spec target_key(target()) :: String.t()
  def target_key(target) when is_map(target) do
    [
      Map.fetch!(target, "binding_name"),
      Map.fetch!(target, "signal_channel_id"),
      Map.get(target, "provider_thread_id", "")
    ]
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp normalize_targets(delivery) do
    case fetch(delivery, "targets") do
      {:ok, targets} when is_list(targets) and targets != [] ->
        targets
        |> Enum.map(&normalize_target/1)
        |> Attrs.collect_results()

      {:ok, _invalid} ->
        {:error, :cron_delivery_route_required}

      :error ->
        {:error, :cron_delivery_route_required}
    end
  end

  defp normalize_target(target) when is_map(target) do
    with {:ok, binding_name} <- Attrs.required_text(target, "binding_name"),
         {:ok, signal_channel_id} <- Attrs.required_text(target, "signal_channel_id") do
      {:ok,
       Attrs.reject_nil_values(%{
         "binding_name" => binding_name,
         "signal_channel_id" => signal_channel_id,
         "provider_thread_id" => Attrs.map_text(target, "provider_thread_id")
       })}
    else
      {:error, _reason} -> {:error, :cron_delivery_route_required}
    end
  end

  defp normalize_target(_target), do: {:error, :cron_delivery_route_required}

  defp validate_primary_binding(
         [%{"binding_name" => binding_name} | _rest],
         binding_name
       ),
       do: :ok

  defp validate_primary_binding(_targets, _binding_name),
    do: {:error, :cron_primary_delivery_binding_mismatch}

  defp validate_unique_targets(targets) do
    keys = Enum.map(targets, &target_key/1)

    if length(keys) == MapSet.size(MapSet.new(keys)),
      do: :ok,
      else: {:error, :duplicate_cron_delivery_target}
  end

  defp normalize_quiet_success(delivery) do
    case fetch(delivery, "quiet_success") do
      :error -> {:ok, :unset}
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_boolean, "quiet_success"}}
    end
  end

  defp preserve_existing_quiet_success(
         _existing,
         %{"quiet_success" => _value} = normalized_update
       ),
       do: {:ok, normalized_update}

  defp preserve_existing_quiet_success(existing, normalized_update) when is_map(existing) do
    case normalize_quiet_success(existing) do
      {:ok, :unset} -> {:ok, normalized_update}
      {:ok, value} -> {:ok, Map.put(normalized_update, "quiet_success", value)}
      {:error, _reason} = error -> error
    end
  end

  defp preserve_existing_quiet_success(_existing, _normalized_update),
    do: {:error, :cron_delivery_route_required}

  defp route_update?(delivery) do
    match?({:ok, _value}, fetch(delivery, "targets"))
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, String.to_atom(key))
    end
  end
end
