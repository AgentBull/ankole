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
  @office_defaults [
    max_file_bytes: 20 * 1024 * 1024,
    compaction_idle_seconds: 30,
    compaction_op_threshold: 100,
    compaction_structural_threshold: 10
  ]
  @action_defaults %{"timeout_ms" => 240_000, "heap_mb" => 192}
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
        key: "pod.applet.action_limits",
        scope: :tenant,
        encrypted: false,
        schema: Schema.new(&validate_applet_limits/1),
        default_value: @action_defaults,
        description:
          "Applet Action slice limits: timeout_ms and heap_mb, including capability wait time."
      ),
      Definition.new!(
        key: "pod.applet.action_runtime_url",
        scope: :global,
        encrypted: false,
        schema: Schema.new(&action_runtime_url/1),
        default_value: nil,
        description:
          "Optional dedicated Function Runtime origin for background Actions. Uses the site's runtime credential; empty uses the shared deployment."
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
        key: "pod.office.limits",
        scope: :tenant,
        encrypted: false,
        schema: Schema.new(&validate_office_limits/1),
        default_value: Map.new(@office_defaults, fn {key, value} -> {to_string(key), value} end),
        description:
          "Office page limits: max_file_bytes for online editing, and compaction_idle_seconds, compaction_op_threshold, and compaction_structural_threshold for writing edits into the file."
      ),
      Definition.new!(
        key: "pod.ot_replay_window",
        scope: :tenant,
        encrypted: false,
        schema: Schema.new(&positive_integer/1),
        default_value: 1000,
        description: "Number of recent document change batches retained for OT replay."
      ),
      Definition.new!(
        key: "pod.ocr_existing_scans",
        scope: :tenant,
        encrypted: false,
        schema: Schema.new(&boolean/1),
        default_value: false,
        description:
          "Sends the scanned PDF pages that no OCR model read at upload to the OCR model. The OCR provider charges for every page."
      )
    ]
  end

  def allow_external_guests?,
    do: AppConfigure.get_by_key("pod.allow_external_guests") == {:ok, true}

  @doc "Whether an administrator agreed to pay for OCR of the scans that were uploaded unread."
  def ocr_existing_scans?,
    do: AppConfigure.get_by_key("pod.ocr_existing_scans") == {:ok, true}

  @doc "Whether the Pod has no value of its own for `pod.ocr_existing_scans`, so the Site's applies."
  def follows_site_ocr_existing_scans? do
    case AppConfigure.resolve_by_key("pod.ocr_existing_scans") do
      {:ok, %{source: :tenant}} -> false
      _site_or_default -> true
    end
  end

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

  def action_limits do
    with {:ok, limits} <- AppConfigure.get_by_key("pod.applet.action_limits"),
         do: {:ok, [timeout_ms: limits["timeout_ms"], heap_mb: limits["heap_mb"], lane: :action]}
  end

  def action_runtime_url do
    {:ok, url} = AppConfigure.get_by_key("pod.applet.action_runtime_url")
    url
  end

  defp action_runtime_url(nil), do: {:ok, nil}

  defp action_runtime_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: path, userinfo: nil, query: nil, fragment: nil}
      when scheme in ["http", "https"] and is_binary(host) and path in [nil, "", "/"] ->
        {:ok, String.trim_trailing(url, "/")}

      _ ->
        {:error, :invalid_runtime_url}
    end
  end

  defp action_runtime_url(_), do: {:error, :invalid_runtime_url}

  defp validate_applet_limits(limits) when is_map(limits) do
    if Enum.sort(Map.keys(limits)) == Enum.sort(Map.keys(@applet_defaults)) and
         Enum.all?(Map.values(limits), &(is_integer(&1) and &1 > 0)),
       do: {:ok, limits},
       else: {:error, :invalid_limits}
  end

  defp validate_applet_limits(_), do: {:error, :invalid_limits}

  @doc "Returns the Office page limits as a map with atom keys."
  def office_limits do
    with {:ok, limits} <- AppConfigure.get_by_key("pod.office.limits"),
         do:
           {:ok,
            Map.new(@office_defaults, fn {key, _default} ->
              {key, Map.fetch!(limits, to_string(key))}
            end)}
  end

  defp validate_office_limits(limits) when is_map(limits) do
    keys = Enum.map(@office_defaults, fn {key, _default} -> to_string(key) end)

    if Enum.sort(Map.keys(limits)) == Enum.sort(keys) and
         Enum.all?(Map.values(limits), &(is_integer(&1) and &1 > 0)),
       do: {:ok, limits},
       else: {:error, :invalid_limits}
  end

  defp validate_office_limits(_), do: {:error, :invalid_limits}

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
