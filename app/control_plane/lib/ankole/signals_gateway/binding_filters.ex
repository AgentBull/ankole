defmodule Ankole.SignalsGateway.BindingFilters do
  @moduledoc """
  Deterministic v1 admission filters for signal bindings.

  v1 intentionally supports only exact equality over a small allowlist. This
  keeps the user model explicit while leaving one stable place to grow future
  rule routing.

  Why only exact-match over a fixed field allowlist: an operator-authored filter
  decides whether a provider event even enters the system, so it must be cheap,
  total, and impossible to misuse. Regex / ranges / arbitrary field paths would
  invite catastrophic-backtracking, atom exhaustion (see `fetch_field/2`), and
  filters whose behavior nobody can predict from the binding config. Exact
  equality on a curated set of normalized fields is auditable and good enough for
  the v1 routing cases (which adapter, which channel kind, which event_type).
  Anything richer is a deliberate future expansion that lives here.
  """

  import Kernel, except: [match?: 2]

  # The only fields a binding filter may key on. Two prefixes (`metadata.` and
  # `channel_metadata.`) reach one level into the normalized JSON maps; every
  # other entry is a top-level IngressFact field. Restricting the set keeps
  # `String.to_existing_atom/1` in `fetch_field/2` safe and makes filters
  # operator-auditable.
  @allowed_fields MapSet.new([
                    "adapter",
                    "binding_name",
                    "signal_channel_id",
                    "provider_entry_id",
                    "provider_thread_id",
                    "channel_kind",
                    "reply_mode",
                    "sender_key",
                    "actor_input_type",
                    "action_id",
                    "metadata.event_type",
                    "metadata.event_kind",
                    "metadata.repository",
                    "channel_metadata.realm",
                    "channel_metadata.repository"
                  ])

  @type result :: :match | :no_match | {:error, term()}

  @doc """
  Evaluates binding filters against a constructed ingress fact.
  """
  @spec match?(map() | nil, map()) :: result()
  def match?(filters, fact)

  # No filter (or an empty object) means "accept everything for this binding" —
  # an operator who configured no rules wants every event from the adapter.
  def match?(nil, _fact), do: :match
  def match?(filters, _fact) when filters == %{}, do: :match

  # v1 grammar is a single `{"eq" => %{field => value}}` envelope (atom or string
  # key, since filters arrive both from Ecto JSON and from in-code callers).
  # `map_size == 1` forbids smuggling extra unrecognized top-level operators.
  def match?(%{"eq" => eq_filters} = filters, fact) when map_size(filters) == 1 do
    match_eq(eq_filters, fact)
  end

  def match?(%{eq: eq_filters} = filters, fact) when map_size(filters) == 1 do
    match_eq(eq_filters, fact)
  end

  # A well-formed map that is not the `eq` envelope is a filter v1 cannot honor;
  # a non-map is malformed config. Both fail closed (error, not silent match) so
  # a broken binding is visible instead of quietly admitting everything.
  def match?(%{} = _filters, _fact), do: {:error, :unsupported_binding_filter}
  def match?(_filters, _fact), do: {:error, :invalid_binding_filter}

  defp match_eq(filters, fact) when is_map(filters) and map_size(filters) == 0 do
    match?(%{}, fact)
  end

  # All listed equalities must hold (AND). Short-circuit on the first miss or
  # error so a bad field name fails fast rather than evaluating the rest.
  defp match_eq(filters, fact) when is_map(filters) do
    filters
    |> Enum.map(fn {field, expected} -> match_field(field, expected, fact) end)
    |> Enum.reduce_while(:match, fn
      :match, :match -> {:cont, :match}
      :no_match, :match -> {:halt, :no_match}
      {:error, _reason} = error, :match -> {:halt, error}
    end)
  end

  defp match_eq(_filters, _fact), do: {:error, :invalid_binding_filter}

  # Both sides must be scalars: the operator-provided `expected` and the value
  # pulled off the fact. Anything non-scalar (a nested map/list) is rejected as
  # an invalid filter rather than compared structurally — v1 only does scalar
  # equality.
  defp match_field(field, expected, fact) do
    with {:ok, field} <- normalize_field(field),
         :ok <- allowed_field?(field),
         :ok <- scalar?(expected),
         {:ok, actual} <- fetch_field(fact, field),
         :ok <- scalar?(actual) do
      compare_scalar(actual, expected)
    end
  end

  defp normalize_field(field) when is_atom(field), do: {:ok, Atom.to_string(field)}
  defp normalize_field(field) when is_binary(field), do: {:ok, field}
  defp normalize_field(_field), do: {:error, :invalid_binding_filter_field}

  defp allowed_field?(field) do
    case MapSet.member?(@allowed_fields, field) do
      true -> :ok
      false -> {:error, {:unsupported_binding_filter_field, field}}
    end
  end

  defp fetch_field(fact, "metadata." <> key), do: fetch_nested(Map.get(fact, :metadata), key)

  defp fetch_field(fact, "channel_metadata." <> key),
    do: fetch_nested(Map.get(fact, :channel_metadata), key)

  # `to_existing_atom` (not `to_atom`) is the safety valve: filter field names
  # are operator strings, and only IngressFact struct keys exist as atoms by the
  # time this runs. An unknown name raises ArgumentError, which we convert into
  # an unsupported-field error instead of minting a new atom from input.
  defp fetch_field(fact, field) do
    fact
    |> Map.get(String.to_existing_atom(field))
    |> normalize_actual()
  rescue
    ArgumentError -> {:error, {:unsupported_binding_filter_field, field}}
  end

  # Metadata maps are JSON-normalized to string keys, so the nested lookup uses
  # the raw key string directly. A missing parent map yields nil (no match)
  # rather than an error: the filter simply does not apply to this fact.
  defp fetch_nested(%{} = map, key), do: map |> Map.get(key) |> normalize_actual()
  defp fetch_nested(_map, _key), do: {:ok, nil}

  # Fact enum fields (channel_kind, reply_mode) are atoms; compare them as
  # strings so a filter written as `"channel_kind" => "im_group"` matches.
  defp normalize_actual(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp normalize_actual(value), do: {:ok, value}

  defp scalar?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: :ok

  defp scalar?(_value), do: {:error, :invalid_binding_filter_value}

  defp compare_scalar(actual, expected) do
    case actual == expected do
      true -> :match
      false -> :no_match
    end
  end
end
