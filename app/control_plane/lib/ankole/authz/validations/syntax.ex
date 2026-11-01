defmodule Ankole.AuthZ.Validations.Syntax do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, opts, _context) do
    field = Keyword.fetch!(opts, :attribute)
    value = Ash.Changeset.get_attribute(changeset, field)

    result =
      case {value, Keyword.fetch!(opts, :kind)} do
        {nil, _kind} ->
          :ok

        {value, :condition} ->
          if Ash.Changeset.get_attribute(changeset, :action) in ~w(node_view node_contribute node_edit node_manage node_comment),
            do: Ankole.AuthZ.Input.validate_drive_condition_source(value),
            else: Ankole.AuthZ.Input.validate_condition_syntax(value)

        {value, :resource_pattern} ->
          Ankole.AuthZ.Input.validate_resource_pattern_syntax(value)
      end

    case result do
      :ok ->
        :ok

      {:error, _message} ->
        message =
          case opts[:kind] do
            :condition -> "is not a valid condition"
            :resource_pattern -> "is not a valid resource pattern"
          end

        {:error, field: field, message: message}
    end
  end
end
