defmodule Ankole.AgentWorkers.WorkerEnv.Changes.PrepareValue do
  @moduledoc false
  use Ash.Resource.Change

  alias Ankole.AgentWorkers.WorkerEnv

  @impl true
  def change(changeset, _opts, _context) do
    scope = Ash.Changeset.get_attribute(changeset, :scope)
    name = Ash.Changeset.get_attribute(changeset, :name)
    attrs = Ash.Changeset.get_argument(changeset, :input)

    with :ok <- WorkerEnv.validate_name(name),
         existing = WorkerEnv.effective_row(scope, name),
         {:ok, secret} <- custom_secret(attrs, existing),
         {:ok, description} <- custom_description(attrs, existing),
         {:ok, value} <- custom_stored_value(attrs, existing, secret, scope, name) do
      changeset
      |> Ash.Changeset.force_change_attribute(:secret, secret)
      |> Ash.Changeset.force_change_attribute(:description, description)
      |> Ash.Changeset.force_change_attribute(:value, value)
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset, Ankole.Ash.DomainError.exception(reason: reason))
    end
  end

  defp custom_stored_value(attrs, existing, secret, scope, name) do
    case Map.fetch(attrs, "value") do
      {:ok, value} when is_binary(value) -> stored_value(value, secret, scope, name)
      {:ok, _value} -> {:error, :invalid_worker_env_value}
      :error -> preserve_custom_stored_value(existing, secret, scope, name)
    end
  end

  defp preserve_custom_stored_value(nil, _secret, _scope, _name),
    do: {:error, :invalid_worker_env_value}

  defp preserve_custom_stored_value(
         %{secret: secret, value: value, scope: scope, name: name},
         secret,
         scope,
         name
       ),
       do: {:ok, value}

  defp preserve_custom_stored_value(%{scope: _} = existing, secret, scope, name) do
    with {:ok, value} <- WorkerEnv.row_value(existing) do
      stored_value(value, secret, scope, name)
    end
  end

  # Flipping secret on an existing row re-seals or re-exposes on this write;
  # an absent flag keeps the stored state instead of silently decrypting.
  defp custom_secret(attrs, existing) do
    case Map.fetch(attrs, "secret") do
      {:ok, secret} when is_boolean(secret) -> {:ok, secret}
      {:ok, _secret} -> {:error, :invalid_worker_env_secret}
      :error -> {:ok, if(existing, do: existing.secret, else: false)}
    end
  end

  defp custom_description(attrs, existing) do
    case Map.fetch(attrs, "description") do
      {:ok, nil} -> {:ok, nil}
      {:ok, description} when is_binary(description) -> {:ok, description}
      {:ok, _description} -> {:error, :invalid_worker_env_description}
      :error -> {:ok, if(existing, do: existing.description, else: nil)}
    end
  end

  defp stored_value(value, false, _scope, _name), do: {:ok, value}

  defp stored_value(value, true, scope, name),
    do: Ankole.SecretKeyBase.seal(value, "worker_env", [scope, name])
end
