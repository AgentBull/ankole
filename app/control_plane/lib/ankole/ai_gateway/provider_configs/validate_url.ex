defmodule Ankole.AIGateway.ProviderConfigs.ValidateURL do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case {Ash.Changeset.changing_attribute?(changeset, :base_url),
          Ash.Changeset.get_attribute(changeset, :base_url)} do
      {false, _value} ->
        :ok

      {true, nil} ->
        :ok

      {true, url} ->
        case URI.new(url) do
          {:ok, %URI{scheme: scheme, host: host}}
          when scheme in ["http", "https"] and is_binary(host) ->
            :ok

          _invalid ->
            {:error, field: :base_url, message: "must be an absolute http(s) URL"}
        end
    end
  end
end
