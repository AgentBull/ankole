defmodule Ankole.Pod.Config do
  @moduledoc "Declared limits and retention policies for Pod content."
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.{Definition, Schema}

  @defaults %{
    "query_rows" => 1000,
    "record_bytes" => 1_000_000,
    "group_count" => 1000,
    "statement_timeout_ms" => 5000
  }
  @limit_keys Map.keys(@defaults)
  @applet_defaults %{"timeout_ms" => 60_000, "heap_mb" => 128}
  def definitions do
    [
      Definition.new!(
        key: "pod.allow_external_guests",
        scope: :tenant,
        encrypted: false,
        schema: Schema.new(&boolean/1),
        default_value: true,
        description: "Allows invited external guests to access shared Pod pages."
      ),
      Definition.new!(
        key: "pod.applet.limits",
        scope: :tenant,
        encrypted: false,
        schema: Schema.new(&validate_applet_limits/1),
        default_value: @applet_defaults,
        description:
          "Applet invocation limits: timeout_ms and heap_mb. Includes capability wait time and external memory."
      ),
      Definition.new!(
        key: "pod.base.limits",
        scope: :tenant,
        encrypted: false,
        schema: Schema.new(&validate/1),
        default_value: @defaults,
        description:
          "Base query and record limits: query_rows, record_bytes, group_count, and statement_timeout_ms."
      ),
      Definition.new!(
        key: "pod.ot_replay_window",
        scope: :tenant,
        encrypted: false,
        schema: Schema.new(&positive_integer/1),
        default_value: 1000,
        description: "Number of recent document change batches retained for OT replay."
      )
    ]
  end

  def allow_external_guests?,
    do: AppConfigure.get_by_key("pod.allow_external_guests") == {:ok, true}

  @doc "Publishes access changes for the configuration's actual affected workspace set."
  def broadcast_guest_access(:tenant), do: Ankole.Pod.Pages.broadcast_access()

  def broadcast_guest_access(:global) do
    Ankole.Tenants.map_active(fn -> Ankole.Pod.Pages.broadcast_access() end)
    :ok
  end

  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(_), do: {:error, :invalid_boolean}

  def ot_replay_window,
    do: AppConfigure.get_tenant_by_key_in_tx("pod.ot_replay_window")

  def limits do
    case AppConfigure.get_by_key("pod.base.limits") do
      {:ok, limits} when is_map(limits) -> {:ok, limits}
      error -> error
    end
  end

  def applet_limits do
    with {:ok, limits} <- AppConfigure.get_by_key("pod.applet.limits"),
         do: {:ok, [timeout_ms: limits["timeout_ms"], heap_mb: limits["heap_mb"]]}
  end

  defp validate_applet_limits(limits) when is_map(limits) do
    if Enum.sort(Map.keys(limits)) == Enum.sort(Map.keys(@applet_defaults)) and
         Enum.all?(Map.values(limits), &(is_integer(&1) and &1 > 0)),
       do: {:ok, limits},
       else: {:error, :invalid_limits}
  end

  defp validate_applet_limits(_), do: {:error, :invalid_limits}

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_), do: {:error, :invalid_positive_integer}

  defp validate(limits) when is_map(limits) do
    if Enum.sort(Map.keys(limits)) == Enum.sort(@limit_keys) and
         Enum.all?(Map.values(limits), &(is_integer(&1) and &1 > 0)),
       do: {:ok, limits},
       else: {:error, :invalid_limits}
  end

  defp validate(_), do: {:error, :invalid_limits}
end
