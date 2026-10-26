defmodule Ankole.AIGateway.ProviderConfigs.Changes.PrepareConfiguration do
  @moduledoc false
  use Ash.Resource.Change

  alias Ankole.AIGateway.ProviderConfigs.Credentials
  alias Ankole.AIGateway.ProviderConfigs.Provider

  @impl true
  def change(changeset, opts, _context) do
    enable? = Keyword.get(opts, :enable?, false)

    if enable? and is_nil(changeset.data.disabled_at) do
      Ash.Changeset.set_result(changeset, {:ok, changeset.data})
    else
      prepare(changeset, enable?)
    end
  end

  defp prepare(changeset, enable?) do
    changeset = Ash.Changeset.set_defaults(changeset, changeset.action_type, true)

    input =
      if enable?, do: %{"disabled_at" => nil}, else: Ash.Changeset.get_argument(changeset, :input)

    input = input |> Ankole.Attrs.normalize_external_attrs() |> normalize_input()

    # Validate identifiers before provider-specific options or credentials use them.
    changeset =
      Enum.reduce([:provider_id, :provider_kind, :base_url], changeset, fn field, current ->
        case Map.fetch(input, Atom.to_string(field)) do
          :error -> current
          {:ok, value} -> Ash.Changeset.change_attribute(current, field, value)
        end
      end)

    if changeset.valid? do
      row = %{changeset.data | id: Ash.Changeset.get_attribute(changeset, :id)}

      case Credentials.provider_attrs_for_write(input, row) do
        {:ok, attrs} ->
          attrs =
            if enable?,
              do: Map.update!(attrs, "credential_pool", &Credentials.rotate_health_revisions/1),
              else: attrs

          Enum.reduce(
            [
              :provider_id,
              :provider_kind,
              :base_url,
              :connection_options,
              :credential_pool,
              :disabled_at
            ],
            changeset,
            fn field, current ->
              case Map.fetch(attrs, Atom.to_string(field)) do
                :error ->
                  current

                {:ok, value} ->
                  Ash.Changeset.force_change_attribute(current, field, value)
              end
            end
          )

        {:error, reason} ->
          Ash.Changeset.add_error(
            changeset,
            Ankole.Errors.Invalid.Rejected.exception(reason: reason)
          )
      end
    else
      changeset
    end
  end

  defp normalize_input(input) do
    Enum.reduce([:provider_id, :provider_kind, :base_url], input, fn field, attrs ->
      key = Atom.to_string(field)

      case Map.fetch(attrs, key) do
        :error -> attrs
        {:ok, value} -> Map.put(attrs, key, normalize(field, value))
      end
    end)
  end

  defp normalize(field, value) when field in [:provider_id, :provider_kind],
    do: Provider.normalize_id(value)

  defp normalize(:base_url, value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp normalize(_field, value), do: value
end
