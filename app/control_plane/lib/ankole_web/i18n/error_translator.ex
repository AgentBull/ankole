defmodule AnkoleWeb.I18n.ErrorTranslator do
  @moduledoc """
  Maps Ecto changeset errors onto deterministic translation keys.

  Ecto's raw error messages are English strings and are not a stable localization
  contract. This module prefers validation metadata such as `:validation`,
  `:kind`, and `:type`, then falls back to a normalized message key only for
  errors that do not provide useful metadata.
  """

  alias Ankole.I18n

  @type error :: {String.t(), keyword() | map()}

  @doc """
  Translates one Ecto-style error tuple.

  The resulting key is still rendered through `Ankole.I18n.t/3`, so missing
  catalog entries remain visible in forms instead of becoming blank text.
  """
  @spec translate_error(error()) :: String.t()
  def translate_error({message, opts}) do
    opts_map = to_opts_map(opts)
    {key, bindings} = key_and_bindings(message, opts_map)
    I18n.t(key, bindings, [])
  end

  # Validation metadata is more durable than the human message string. Length
  # errors get a type class because strings, binaries, and collections need
  # different wording in many languages.
  defp key_and_bindings(message, opts) do
    case {Map.get(opts, :validation), Map.get(opts, :kind)} do
      {:length, kind} when not is_nil(kind) ->
        type_class = length_type_class(Map.get(opts, :type))
        {"errors.validation.length.#{type_class}.#{kind}", opts}

      {validation, kind}
      when is_atom(validation) and not is_nil(validation) and not is_nil(kind) ->
        {"errors.validation.#{validation}.#{kind}", opts}

      {validation, nil} when is_atom(validation) and not is_nil(validation) ->
        {"errors.validation.#{validation}", opts}

      {nil, _kind} ->
        {"errors.#{normalize_message(message)}", opts}
    end
  end

  defp length_type_class(:string), do: "string"
  defp length_type_class(:binary), do: "binary"
  defp length_type_class(type) when type in [:list, :map], do: "collection"
  defp length_type_class(_type), do: "string"

  # This fallback is intentionally simple and ASCII-oriented because it only
  # covers built-in English Ecto messages or custom errors without metadata. A
  # catalog miss stays visible through `I18n.t/3`.
  defp normalize_message(message) when is_binary(message) do
    message
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  # Changeset options are normally keywords, but accepting maps and unknown
  # values keeps this translator tolerant at the boundary with custom validators.
  defp to_opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp to_opts_map(opts) when is_map(opts), do: opts
  defp to_opts_map(_opts), do: %{}
end
