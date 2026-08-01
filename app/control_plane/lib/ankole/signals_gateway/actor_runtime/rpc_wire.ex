defmodule Ankole.SignalsGateway.ActorRuntime.RPCWire do
  @moduledoc """
  Shared helpers for RuntimeFabric RPC broker error payloads and the JSON
  documents carried inside `*_json` payload fields.

  Request and response payloads themselves are generated protobuf structs
  decoded by `RPCLane`; these map readers exist only for the deliberately
  free-form documents (reply routes, metadata, library projections) and keep
  the `rpc_error` payload shape consistent.
  """

  @type error_message_style :: :default | :tuple_reason | :inspect_tuple_reason | :tuple_inspect

  alias Ankole.RuntimeFabric.V1, as: FabricProto

  @doc """
  Reads a possibly string-keyed or atom-keyed value without creating atoms.
  """
  def value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || atom_key_value(map, key)
  end

  def value(_map, _key), do: nil

  @doc """
  Reads a non-empty binary field, trimming whitespace by default.
  """
  def text(map, key, opts \\ []) do
    case value(map, key) do
      value when is_binary(value) ->
        if Keyword.get(opts, :trim, true) do
          case String.trim(value) do
            "" -> nil
            trimmed -> trimmed
          end
        else
          value
        end

      _value ->
        nil
    end
  end

  @doc """
  Reads a map field, returning the configured default for missing or invalid values.
  """
  def map_value(map, key, default \\ nil) do
    case value(map, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  @doc """
  Projects one library Skill record into the shared RuntimeFabric summary.
  """
  def runtime_skill_summary(skill) when is_map(skill) do
    metadata = map_value(skill, "metadata", %{})

    %FabricProto.RuntimeSkillSummary{
      skill_name: text(skill, "skill_name") || "",
      description: text(skill, "description", trim: false) || "",
      default_enabled: boolean_or_nil(value(skill, "default_enabled")),
      source_kind: text(skill, "source_kind") || "",
      agent_plugin_id: text(skill, "agent_plugin_id") || "",
      relative_path: text(skill, "relative_path") || "",
      skill_root: text(skill, "skill_root") || "",
      metadata_json: encode_optional_json(metadata),
      category: text(skill, "category") || "",
      tags_json: encode_optional_json(value(skill, "tags")),
      skill_uri: text(skill, "skill_uri") || "",
      has_agent_overlay: value(skill, "has_agent_overlay") == true
    }
  end

  @doc """
  Recursively converts atom keys to string keys for wire-originated maps.
  """
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) and is_map(value) ->
        {Atom.to_string(key), stringify_keys(value)}

      {key, value} when is_atom(key) ->
        {Atom.to_string(key), value}

      {key, value} when is_map(value) ->
        {key, stringify_keys(value)}

      pair ->
        pair
    end)
  end

  @doc """
  Builds a broker method error payload. The RPCLane wraps this in `rpc_error`.
  """
  def error_payload(request_id, reason, opts) when is_list(opts) do
    fallback_code = Keyword.fetch!(opts, :fallback_code)

    %{
      "request_id" => request_id,
      "code" => error_code(reason, fallback_code, opts),
      "message" => error_message(reason, Keyword.get(opts, :message_style, :default)),
      "details_json" => Keyword.get(opts, :details_json, %{})
    }
  end

  def error_code(reason, fallback_code, opts \\ [])
  def error_code(reason, _fallback_code, _opts) when is_atom(reason), do: Atom.to_string(reason)

  def error_code(%Ecto.Changeset{}, fallback_code, opts) do
    Keyword.get(opts, :changeset_code, fallback_code)
  end

  def error_code({reason, _details}, _fallback_code, _opts) when is_atom(reason),
    do: Atom.to_string(reason)

  def error_code({reason, _key, _details}, _fallback_code, _opts) when is_atom(reason),
    do: Atom.to_string(reason)

  def error_code(_reason, fallback_code, _opts), do: fallback_code

  def error_message(reason, style \\ :default)
  def error_message(%Ecto.Changeset{} = changeset, _style), do: inspect(changeset.errors)
  def error_message(reason, _style) when is_atom(reason), do: Atom.to_string(reason)

  def error_message({reason, _details}, :tuple_reason) when is_atom(reason),
    do: Atom.to_string(reason)

  def error_message({reason, details}, :inspect_tuple_reason) when is_atom(reason),
    do: "#{inspect(reason)}: #{inspect(details)}"

  def error_message({_reason, _details} = reason, :tuple_inspect), do: inspect(reason)
  def error_message({_reason, _key, _details} = reason, :tuple_inspect), do: inspect(reason)

  def error_message({reason, details}, _style) when is_atom(reason),
    do: "#{reason}: #{inspect(details)}"

  def error_message(reason, _style), do: inspect(reason)

  defp boolean_or_nil(value) when is_boolean(value), do: value
  defp boolean_or_nil(_value), do: nil

  defp encode_optional_json(nil), do: ""
  defp encode_optional_json(value) when value == %{}, do: ""
  defp encode_optional_json(value) when value == [], do: ""
  defp encode_optional_json(value), do: Torque.encode!(value)

  defp atom_key_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end
end
