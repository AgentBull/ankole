defmodule Ankole.Observability.Trace do
  @moduledoc """
  Single owner of the span facts that Ankole trace builders share.

  `Ankole.Observability` builds turn root spans, and
  `Ankole.AIGateway.Observability` builds response, generation, and compact
  spans. Both get the shared attribute vocabulary, the content encoding with
  its redaction rules, and the small span helpers from this module.
  """

  alias Ankole.Observability.Provider
  alias OpenTelemetry.Span

  @content_limit_bytes 1024 * 1024
  @redacted_keys ~w(
    access_token
    api_key
    authorization
    encrypted_content
    encrypted_function_args
    headers
    metadata
    refresh_token
    secret_key
  )

  @doc """
  Returns the trace attributes that every Ankole root span shares.

  Each span owner adds its own namespace keys on top of this map; domain keys
  such as `ankole.ai_gateway.*` or `ankole.background_agent_job.*` do not
  belong here.
  """
  @spec trace_attributes(Provider.trace_context()) :: map()
  def trace_attributes(context) do
    %{}
    |> maybe_put("ankole.principal.uid", context.principal_uid)
    |> maybe_put("user.id", context.user_id)
    |> maybe_put("ankole.principal.type", context.principal_type)
    |> maybe_put("session.id", context.session_id)
    |> maybe_put("gen_ai.conversation.id", context.session_id)
    |> maybe_put("ankole.actor_event.id", context.actor_event_id)
  end

  @doc """
  Encodes one value as sanitized JSON for span content attributes.

  Returns the encoded text and a flag that tells whether an omission marker
  replaced the content.
  """
  @spec encode_content(term()) :: {String.t(), boolean()}
  def encode_content(value) do
    value
    |> sanitize()
    |> Ankole.JSON.encode()
    |> case do
      {:ok, encoded} when byte_size(encoded) <= @content_limit_bytes ->
        {encoded, false}

      {:ok, encoded} ->
        marker = %{"omitted" => "content_too_large", "original_bytes" => byte_size(encoded)}
        {:ok, marker} = Ankole.JSON.encode(marker)
        {marker, true}

      {:error, _reason} ->
        {~s({"omitted":"encoding_failed"}), true}
    end
  end

  @doc """
  Removes credential keys and inline data from a value before export.
  """
  @spec sanitize(term()) :: term()
  def sanitize(values) when is_list(values), do: Enum.map(values, &sanitize/1)

  def sanitize(%{} = value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      key = to_string(key)

      if redacted_key?(key) do
        acc
      else
        Map.put(acc, key, sanitize(nested))
      end
    end)
  end

  def sanitize(value) when is_binary(value) do
    if String.starts_with?(value, "data:") do
      %{"omitted" => "inline_data", "original_bytes" => byte_size(value)}
    else
      value
    end
  end

  def sanitize(value) when is_atom(value), do: Atom.to_string(value)
  def sanitize(value), do: value

  @spec release() :: String.t() | nil
  def release, do: text(System.get_env("ANKOLE_VERSION"))

  def tracer, do: :opentelemetry.get_tracer(:ankole, :undefined, :undefined)

  def mark_error(span, error_type) do
    Span.set_attribute(span, "error.type", error_type)
    Span.set_status(span, OpenTelemetry.status(:error, error_type))
  end

  @spec map_value(term(), String.t()) :: term()
  def map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {map_key, value} when is_atom(map_key) ->
          if Atom.to_string(map_key) == key, do: value

        _entry ->
          nil
      end)
  end

  def map_value(_map, _key), do: nil

  @spec text(term()) :: String.t() | nil
  def text(nil), do: nil
  def text(value) when is_atom(value), do: Atom.to_string(value)

  def text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  def text(_value), do: nil

  @spec maybe_put(map(), String.t(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, _key, ""), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec maybe_put_true(map(), String.t(), boolean()) :: map()
  def maybe_put_true(map, key, true), do: Map.put(map, key, true)
  def maybe_put_true(map, _key, false), do: map

  # Tracing must never change product behavior: every observability entry
  # point runs its body through safe/2, so a tracing failure degrades to
  # missing trace data.
  @spec safe(term(), (-> term())) :: term()
  def safe(fallback, fun) do
    fun.()
  rescue
    _error -> fallback
  catch
    _kind, _reason -> fallback
  end

  defp redacted_key?("__ankole_" <> _rest), do: true
  defp redacted_key?(key), do: String.downcase(key) in @redacted_keys
end
