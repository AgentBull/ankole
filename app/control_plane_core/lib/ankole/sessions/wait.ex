defmodule Ankole.Sessions.Wait do
  @moduledoc "A durable observation window for a tool's committed operation."
  @enforce_keys [:kind, :timeout_ms]
  defstruct [
    :kind,
    :timeout_ms,
    :started_at,
    :job_id,
    :command_event_id,
    :binding_name,
    :outbound_key
  ]

  @type t :: %__MODULE__{}

  @spec owner(t()) :: module()
  def owner(%__MODULE__{kind: :job}), do: Ankole.Sessions.Tools.Jobs
  def owner(%__MODULE__{kind: :outbox}), do: Ankole.Sessions.Tools.Message

  @spec encode(t()) :: map()
  def encode(wait) do
    wait
    |> Map.from_struct()
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Ankole.Attrs.normalize_external_attrs()
    |> Map.put("kind", Atom.to_string(wait.kind))
    |> Map.put("started_at", if(wait.started_at, do: DateTime.to_iso8601(wait.started_at)))
  end

  @spec decode(map(), DateTime.t()) :: t()
  def decode(value, inserted_at) do
    kind =
      case value["kind"] do
        "job" -> :job
        "outbox" -> :outbox
      end

    attrs =
      for key <- ~w(timeout_ms job_id command_event_id binding_name outbound_key),
          into: %{},
          do: {String.to_existing_atom(key), value[key]}

    struct!(__MODULE__, Map.merge(attrs, %{kind: kind, started_at: inserted_at}))
  end
end
