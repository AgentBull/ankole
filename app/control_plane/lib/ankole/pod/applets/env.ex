defmodule Ankole.Pod.Applets.Env do
  @moduledoc """
  Resolves and manages the three-tier environment for Pod Applets.

  Effective runtime values merge in ascending precedence:
  `Site (global)` -> `Pod (tenant)` -> `applet.env.json defaults` -> `Applet (pod_applet_envs)`.
  `applet.env.json` accepts both legacy string maps (`{"KEY": "val"}`) and
  structured variable contracts (`{"KEY": {"default"?, "required"?, "secret"?, "description"?}}`).
  """

  require Ash.Query

  alias Ankole.{AgentWorkers, Files, Repo}
  alias Ankole.Pod.{Access, AppletEnv, Pages}

  @max_env_bytes 65_536
  @spec_keys ~w(default required secret description)

  @doc "Parses `applet.env.json` bytes into default values and variable declarations."
  def parse_manifest(nil), do: {:ok, %{defaults: %{}, specs: %{}}}

  def parse_manifest(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_env_bytes do
    case Torque.decode(bytes) do
      {:ok, raw} when is_map(raw) ->
        Enum.reduce_while(raw, {:ok, %{defaults: %{}, specs: %{}}}, fn entry, {:ok, acc} ->
          case parse_manifest_entry(entry) do
            {:ok, key, spec} ->
              defaults =
                if is_binary(spec.default),
                  do: Map.put(acc.defaults, key, spec.default),
                  else: acc.defaults

              {:cont, {:ok, %{defaults: defaults, specs: Map.put(acc.specs, key, spec)}}}

            {:error, _} = error ->
              {:halt, error}
          end
        end)

      _ ->
        {:error, :invalid_manifest}
    end
  end

  def parse_manifest(_bytes), do: {:error, :invalid_manifest}

  defp parse_manifest_entry({key, value})
       when is_binary(key) and key != "" and is_binary(value) do
    with :ok <- valid_manifest_name(key),
         :ok <- valid_manifest_default(value) do
      {:ok, key, %{default: value, required: false, secret: false, description: nil}}
    end
  end

  defp parse_manifest_entry({key, spec}) when is_binary(key) and is_map(spec) do
    with :ok <- valid_manifest_name(key),
         true <- Enum.all?(Map.keys(spec), &(&1 in @spec_keys)),
         {:ok, default} <- optional_string_or_nil(spec, "default"),
         :ok <- valid_manifest_default(default),
         {:ok, required} <- optional_boolean(spec, "required", false),
         {:ok, secret} <- optional_boolean(spec, "secret", false),
         {:ok, description} <- optional_string_or_nil(spec, "description") do
      {:ok, key,
       %{default: default, required: required, secret: secret, description: description}}
    else
      _ -> {:error, :invalid_manifest}
    end
  end

  defp parse_manifest_entry(_entry), do: {:error, :invalid_manifest}

  defp valid_manifest_default(nil), do: :ok

  defp valid_manifest_default(value) when is_binary(value) do
    if Regex.match?(~r/\S/, value), do: :ok, else: {:error, :invalid_manifest}
  end

  defp valid_manifest_name(key) do
    case AgentWorkers.validate_worker_env_name(key) do
      :ok -> :ok
      {:error, _} -> {:error, :invalid_manifest}
    end
  end

  defp optional_string_or_nil(map, key) do
    case Map.fetch(map, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _} -> :error
    end
  end

  defp optional_boolean(map, key, default) do
    case Map.fetch(map, key) do
      :error -> {:ok, default}
      {:ok, nil} -> {:ok, default}
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _} -> :error
    end
  end

  @doc "Resolves the merged runtime environment map for an Applet from its manifest object ID."
  def effective_env_from_object(page_id, nil),
    do: effective_env_from_manifest(page_id, %{defaults: %{}, specs: %{}})

  def effective_env_from_object(page_id, object_id) when is_binary(object_id) do
    with {:ok, bytes} <- Files.read_object(object_id),
         {:ok, manifest} <- parse_manifest(bytes),
         do: effective_env_from_manifest(page_id, manifest)
  end

  @doc "Resolves the merged runtime environment map from a parsed manifest."
  def effective_env_from_manifest(page_id, manifest) do
    defaults = Map.get(manifest, :defaults, %{})
    specs = Map.get(manifest, :specs, %{})

    with {:ok, inherited} <- AgentWorkers.applet_inherited_env_values(),
         {:ok, applet_vals} <- applet_values(page_id) do
      merge_within_budget(inherited, defaults, specs, applet_vals)
    end
  end

  @doc "Returns missing required variable count for `node_view` callers without exposing names."
  def status(%Ankole.AuthZ.Actor{} = actor, page_id) do
    Repo.transact_top_level(fn ->
      with {:ok, page} <- Pages.lock(page_id, :share),
           :ok <- require_applet(page),
           {:ok, _} <- Pages.authorize(actor, page.id, "node_view", trash: false),
           {:ok, manifest} <- load_page_manifest(page.id),
           {:ok, inherited} <- AgentWorkers.applet_inherited_env_items() do
        applet_rows = applet_rows_by_name(page.id)

        missing_count =
          manifest.specs
          |> Enum.count(fn {name, spec} ->
            spec.required and
              not is_binary(spec.default) and
              not Map.has_key?(inherited, name) and
              not Map.has_key?(applet_rows, name)
          end)

        {:ok, %{missing_required_count: missing_count}}
      end
    end)
  end

  @doc "Lists effective, inherited, and missing declared variables for an Applet editor."
  def list(%Ankole.AuthZ.Actor{} = actor, page_id) do
    Repo.transact_top_level(fn ->
      with {:ok, page} <- Pages.lock(page_id, :share),
           :ok <- require_applet(page),
           {:ok, _} <- Pages.authorize(actor, page.id, "node_edit", trash: false),
           {:ok, manifest} <- load_page_manifest(page.id),
           {:ok, inherited} <- AgentWorkers.applet_inherited_env_items() do
        applet_rows = applet_rows_by_name(page.id)
        can_decrypt = can_decrypt?(actor, page.id)

        {:ok,
         %{
           can_decrypt: can_decrypt,
           envs: project_items(inherited, manifest.specs, applet_rows)
         }}
      end
    end)
  end

  @doc "Creates or updates an Applet-scoped variable override (`node_edit`)."
  def put(%Ankole.AuthZ.Actor{} = actor, page_id, name, attrs) when is_map(attrs) do
    Access.write(actor.turn_authority, fn ->
      with :ok <- validate_name(name),
           {:ok, page} <- Pages.lock(page_id),
           :ok <- require_applet(page),
           {:ok, _} <- Pages.authorize(actor, page.id, "node_edit", trash: false),
           {:ok, manifest} <- load_page_manifest(page.id),
           {:ok, inherited} <- AgentWorkers.applet_inherited_env_items(),
           existing = applet_row(page.id, name),
           spec = Map.get(manifest.specs, name),
           {:ok, secret} <- resolve_secret(attrs, existing, spec),
           {:ok, description} <- resolve_description(attrs, existing),
           {:ok, plain_value, stored_value} <-
             prepare_stored_value(attrs, existing, secret, page.id, name),
           :ok <- ensure_effective_budget(page.id, manifest, name, plain_value),
           {:ok, row} <-
             Ankole.Ash.create(AppletEnv, :put_in_tx, %{
               page_id: page.id,
               name: name,
               secret: secret,
               value: stored_value,
               description: description
             }) do
        {:ok, project_item(name, Map.get(inherited, name), spec, row)}
      end
    end)
  end

  @doc "Deletes an Applet-scoped variable override and returns its resulting fallback state (`node_edit`)."
  def delete(%Ankole.AuthZ.Actor{} = actor, page_id, name) do
    Access.write(actor.turn_authority, fn ->
      with :ok <- validate_name(name),
           {:ok, page} <- Pages.lock(page_id),
           :ok <- require_applet(page),
           {:ok, _} <- Pages.authorize(actor, page.id, "node_edit", trash: false),
           {:ok, manifest} <- load_page_manifest(page.id),
           {:ok, inherited} <- AgentWorkers.applet_inherited_env_items() do
        case applet_row(page.id, name) do
          nil ->
            if Map.has_key?(inherited, name),
              do: {:error, :forbidden},
              else: {:error, :not_found}

          row ->
            with {:ok, _} <- Ankole.Ash.destroy(row, :remove) do
              {:ok,
               project_item(name, Map.get(inherited, name), Map.get(manifest.specs, name), nil)}
            end
        end
      end
    end)
  end

  @doc "Decrypts an Applet-scoped secret variable; requires a Human principal with `node_manage`."
  def decrypt(%Ankole.AuthZ.Actor{} = actor, page_id, name) do
    Repo.transact_top_level(fn ->
      with :ok <- require_human(actor),
           :ok <- validate_name(name),
           {:ok, page} <- Pages.lock(page_id, :share),
           :ok <- require_applet(page),
           {:ok, _} <- Pages.authorize(actor, page.id, "node_manage", trash: false),
           do: decrypt_row(page.id, name)
    end)
  end

  defp decrypt_row(page_id, name) do
    case applet_row(page_id, name) do
      nil ->
        with {:ok, inherited} <- AgentWorkers.applet_inherited_env_items() do
          if Map.has_key?(inherited, name), do: {:error, :forbidden}, else: {:error, :not_found}
        end

      %{secret: false} ->
        {:error, :not_encrypted}

      %{secret: true} = row ->
        row_value(row)
    end
  end

  defp can_decrypt?(actor, page_id) do
    require_human(actor) == :ok and
      match?({:ok, _}, Pages.authorize(actor, page_id, "node_manage", trash: false))
  end

  defp require_human(%{principal: %{type: :human}}), do: :ok
  defp require_human(_actor), do: {:error, :forbidden}

  defp require_applet(%{type: :applet}), do: :ok
  defp require_applet(_page), do: {:error, :not_found}

  defp validate_name(name), do: AgentWorkers.validate_worker_env_name(name)

  defp load_page_manifest(page_id) do
    case Ankole.Pod.Files.fetch_file(page_id, "applet.env.json") do
      {:ok, file} ->
        with {:ok, bytes} <- Files.read_object(file.object_id),
             do: parse_manifest(bytes)

      {:error, :not_found} ->
        {:ok, %{defaults: %{}, specs: %{}}}

      error ->
        error
    end
  end

  defp applet_rows_by_name(page_id) do
    AppletEnv
    |> Ash.Query.filter(page_id == ^page_id)
    |> Ankole.Ash.read!()
    |> Map.new(&{&1.name, &1})
  end

  defp applet_row(page_id, name) do
    AppletEnv
    |> Ash.Query.filter(page_id == ^page_id and name == ^name)
    |> Ankole.Ash.read_one!()
  end

  defp applet_values(page_id) do
    AppletEnv
    |> Ash.Query.filter(page_id == ^page_id)
    |> Ankole.Ash.read!()
    |> Enum.reduce_while({:ok, %{}}, fn row, {:ok, acc} ->
      case row_value(row) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, row.name, value)}}
        {:error, reason} -> {:halt, {:error, {:applet_env_row_error, page_id, row.name, reason}}}
      end
    end)
  end

  defp row_value(%AppletEnv{secret: false, value: value}), do: {:ok, value}

  defp row_value(%AppletEnv{secret: true, page_id: page_id, name: name, value: ciphertext}) do
    Ankole.SecretKeyBase.unseal(ciphertext, "pod_applet_env", [
      Repo.tenant_id!(),
      page_id,
      name
    ])
  end

  defp resolve_secret(attrs, existing, spec) do
    case fetch_attr(attrs, :secret) do
      {:ok, nil} ->
        default_secret(existing, spec)

      {:ok, value} when is_boolean(value) ->
        {:ok, value}

      {:ok, _} ->
        {:error, :invalid_worker_env_secret}

      :error ->
        default_secret(existing, spec)
    end
  end

  defp default_secret(existing, spec) do
    cond do
      existing != nil -> {:ok, existing.secret}
      spec != nil -> {:ok, spec.secret}
      true -> {:ok, false}
    end
  end

  defp resolve_description(attrs, existing) do
    case fetch_attr(attrs, :description) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_binary(value) -> {:ok, if(value == "", do: nil, else: value)}
      {:ok, _} -> {:error, :invalid_worker_env_description}
      :error -> {:ok, if(existing, do: existing.description, else: nil)}
    end
  end

  defp prepare_stored_value(attrs, existing, secret, page_id, name) do
    case fetch_attr(attrs, :value) do
      {:ok, nil} when existing != nil ->
        preserve_stored_value(existing, secret, page_id, name)

      {:ok, value} when is_binary(value) ->
        if Regex.match?(~r/\S/, value) do
          with {:ok, stored} <- seal_if_secret(value, secret, page_id, name),
               do: {:ok, value, stored}
        else
          {:error, :invalid_worker_env_value}
        end

      {:ok, _} ->
        {:error, :invalid_worker_env_value}

      :error ->
        preserve_stored_value(existing, secret, page_id, name)
    end
  end

  defp preserve_stored_value(nil, _secret, _page_id, _name),
    do: {:error, :invalid_worker_env_value}

  defp preserve_stored_value(%AppletEnv{secret: true}, false, _page_id, _name),
    do: {:error, :invalid_worker_env_value}

  defp preserve_stored_value(%AppletEnv{} = row, secret, page_id, name) do
    with {:ok, plain} <- row_value(row),
         {:ok, stored} <- seal_if_secret(plain, secret, page_id, name),
         do: {:ok, plain, stored}
  end

  defp seal_if_secret(value, false, _page_id, _name), do: {:ok, value}

  defp seal_if_secret(value, true, page_id, name) do
    Ankole.SecretKeyBase.seal(value, "pod_applet_env", [Repo.tenant_id!(), page_id, name])
  end

  defp ensure_effective_budget(page_id, manifest, updated_name, updated_plain_value) do
    defaults = Map.get(manifest, :defaults, %{})
    specs = Map.get(manifest, :specs, %{})

    with {:ok, inherited} <- AgentWorkers.applet_inherited_env_values(),
         {:ok, applet_vals} <- applet_values(page_id),
         {:ok, _merged} <-
           merge_within_budget(
             inherited,
             defaults,
             specs,
             Map.put(applet_vals, updated_name, updated_plain_value)
           ),
         do: :ok
  end

  defp merge_within_budget(inherited, defaults, specs, applet_vals) do
    full = inherited |> Map.merge(defaults) |> Map.merge(applet_vals)

    if byte_size(Torque.encode!(full)) <= @max_env_bytes do
      {:ok, full}
    else
      core =
        inherited
        |> Map.take(Map.keys(specs))
        |> Map.merge(defaults)
        |> Map.merge(applet_vals)

      if byte_size(Torque.encode!(core)) > @max_env_bytes do
        {:error, :applet_env_too_large}
      else
        undeclared =
          inherited
          |> Map.drop(Map.keys(core))
          |> Enum.sort_by(fn {key, value} -> {byte_size(key) + byte_size(value), key} end)

        packed =
          Enum.reduce(undeclared, core, fn {key, value}, acc ->
            candidate = Map.put(acc, key, value)
            if byte_size(Torque.encode!(candidate)) <= @max_env_bytes, do: candidate, else: acc
          end)

        {:ok, packed}
      end
    end
  end

  defp fetch_attr(attrs, key) do
    str_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> {:ok, Map.get(attrs, key)}
      Map.has_key?(attrs, str_key) -> {:ok, Map.get(attrs, str_key)}
      true -> :error
    end
  end

  defp project_items(inherited, specs, applet_rows) do
    (Map.keys(inherited) ++ Map.keys(specs) ++ Map.keys(applet_rows))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn name ->
      project_item(
        name,
        Map.get(inherited, name),
        Map.get(specs, name),
        Map.get(applet_rows, name)
      )
    end)
  end

  defp project_item(name, inh, spec, %{} = app) do
    %{
      name: name,
      secret: app.secret,
      required: spec_required?(spec),
      declared: spec != nil,
      description: first_present([app.description, spec_description(spec), inh_description(inh)]),
      present: true,
      source: :applet,
      inherited_source: fallback_below_applet(inh, spec)
    }
    |> maybe_put_value(app.secret, app.value)
  end

  defp project_item(name, inh, %{default: default} = spec, nil) when is_binary(default) do
    %{
      name: name,
      secret: spec.secret,
      required: spec.required,
      declared: true,
      description: first_present([spec.description, inh_description(inh)]),
      present: true,
      source: :default,
      inherited_source: inh && inh.source
    }
    |> maybe_put_value(spec.secret, default)
  end

  defp project_item(name, %{} = inh, spec, nil) do
    secret = inh.secret or spec_secret?(spec)

    %{
      name: name,
      secret: secret,
      required: spec_required?(spec),
      declared: spec != nil,
      description: first_present([spec_description(spec), inh.description]),
      present: true,
      source: inh.source,
      inherited_source: nil
    }
    |> maybe_put_value(secret, Map.get(inh, :value))
  end

  defp project_item(name, nil, %{} = spec, nil) do
    %{
      name: name,
      secret: spec.secret,
      required: spec.required,
      declared: true,
      description: spec.description,
      present: false,
      source: :missing,
      inherited_source: nil
    }
  end

  defp project_item(name, nil, nil, nil) do
    %{
      name: name,
      secret: false,
      required: false,
      declared: false,
      description: nil,
      present: false,
      source: :missing,
      inherited_source: nil
    }
  end

  defp fallback_below_applet(_inh, %{default: default}) when is_binary(default), do: :default
  defp fallback_below_applet(%{source: source}, _spec), do: source
  defp fallback_below_applet(nil, _spec), do: nil

  defp spec_required?(%{required: required}), do: required
  defp spec_required?(nil), do: false

  defp spec_secret?(%{secret: secret}), do: secret
  defp spec_secret?(nil), do: false

  defp spec_description(%{description: description}), do: description
  defp spec_description(nil), do: nil

  defp inh_description(%{description: description}), do: description
  defp inh_description(nil), do: nil

  defp first_present(values), do: Enum.find(values, &(not is_nil(&1)))

  defp maybe_put_value(item, true, _value), do: item
  defp maybe_put_value(item, false, nil), do: item
  defp maybe_put_value(item, false, value), do: Map.put(item, :value, value)
end
