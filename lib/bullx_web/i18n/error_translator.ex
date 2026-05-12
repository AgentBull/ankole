defmodule BullXWeb.I18n.ErrorTranslator do
  @moduledoc """
  Maps Ecto changeset errors onto deterministic validation keys.

  Ecto delivers errors as `{msg, opts}` where `opts` usually carries
  a `:validation` atom and sometimes a `:kind`, `:type`, or other
  parameters. The translator selects a key as follows:

    1. `validation: :length, kind: <m>, type: <t>` →
       `errors.validation.length.<type_class>.<kind>` with
       `type_class` normalised to `:string`, `:binary`, or
       `:collection`.
    2. `validation: <v>, kind: <k>` →
       `errors.validation.<v>.<k>`.
    3. `validation: <v>` → `errors.validation.<v>`.
    4. Fallback: `errors.<normalised_msg>`.

  Remaining opts are passed as MF2 bindings.
  """

  alias BullX.I18n

  @type error :: {String.t(), Keyword.t() | map()}

  @spec translate_error(error()) :: String.t()
  def translate_error({msg, opts}) do
    opts_map = to_opts_map(opts)
    {key, bindings} = key_and_bindings(msg, opts_map)
    I18n.t(key, bindings, [])
  end

  defp key_and_bindings(msg, opts) do
    case {Map.get(opts, :validation), Map.get(opts, :kind)} do
      {:length, kind} when not is_nil(kind) ->
        type_class = length_type_class(Map.get(opts, :type))
        {"errors.validation.length.#{type_class}.#{kind}", opts}

      {validation, kind}
      when is_atom(validation) and not is_nil(validation) and not is_nil(kind) ->
        {"errors.validation.#{validation}.#{kind}", opts}

      {validation, nil} when is_atom(validation) and not is_nil(validation) ->
        {"errors.validation.#{validation}", opts}

      {nil, _} ->
        {"errors.#{normalise_msg(msg)}", opts}
    end
  end

  defp length_type_class(:string), do: "string"
  defp length_type_class(:binary), do: "binary"
  defp length_type_class(type) when type in [:list, :map], do: "collection"
  # Default to :string, which matches Ecto's behaviour for string inputs.
  defp length_type_class(_), do: "string"

  defp normalise_msg(msg) when is_binary(msg) do
    msg
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp to_opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp to_opts_map(opts) when is_map(opts), do: opts
  defp to_opts_map(_), do: %{}
end
