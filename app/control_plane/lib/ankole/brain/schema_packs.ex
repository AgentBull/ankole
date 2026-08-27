defmodule Ankole.Brain.SchemaPacks do
  @moduledoc """
  Schema pack seeds, merge validation, and installation.

  Seeds are repository files under `priv/brain/schema_packs/`. Installation
  materializes the selected seeds into the `brain_schema_*` tables in one
  transaction; after that the tables own the instance ontology, and later
  promotions or pack additions write the same tables through the same merge
  validation. Pack seeds are never read on the write path.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Schemas.SchemaCalibrationDomain
  alias Ankole.Brain.Schemas.SchemaLinkType
  alias Ankole.Brain.Schemas.SchemaPack
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Repo

  @api_version "ankole-brain-schema-pack-v1"
  @base_pack "general"
  @industry_packs ~w(pevc public_markets consumer legal software consulting)
  @primitives ~w(entity media temporal annotation concept)

  @type manifest :: map()

  @doc "Returns the base pack name that every installation includes."
  @spec base_pack() :: String.t()
  def base_pack, do: @base_pack

  @doc "Returns the selectable industry pack names."
  @spec industry_packs() :: [String.t()]
  def industry_packs, do: @industry_packs

  @doc """
  Loads one pack seed from the repository.
  """
  @spec load_seed(String.t()) ::
          {:ok, %{manifest: manifest(), content_hash: String.t()}} | {:error, term()}
  def load_seed(name) when is_binary(name) do
    if name in [@base_pack | @industry_packs] do
      path = Path.join(seeds_root(), name <> ".yaml")

      with {:ok, raw} <- File.read(path),
           {:ok, manifest} <- parse_manifest(name, raw) do
        {:ok, %{manifest: manifest, content_hash: NativeKernel.xxh3_128_hex(raw)}}
      else
        {:error, %YamlElixir.ParsingError{} = error} ->
          {:error, {:invalid_pack_seed, name, Exception.message(error)}}

        {:error, reason} ->
          {:error, {:invalid_pack_seed, name, reason}}
      end
    else
      {:error, {:unknown_pack, name}}
    end
  end

  @doc """
  Validates a pack selection without writing anything.

  The selection is normalized to always include the base pack. Validation
  covers seed shape, increment rules, and the multi-select merge rules.
  """
  @spec validate_selection([String.t()]) :: {:ok, merged :: map()} | {:error, term()}
  def validate_selection(names) when is_list(names) do
    with {:ok, ordered} <- normalize_selection(names),
         {:ok, seeds} <- load_seeds(ordered) do
      merge_manifests(Enum.map(seeds, & &1.manifest))
    end
  end

  @doc """
  Lists installed packs ordered by installation time.
  """
  @spec installed_packs() :: [SchemaPack.t()]
  def installed_packs do
    SchemaPack
    |> order_by([pack], asc: pack.installed_at)
    |> Repo.all()
  end

  @doc """
  Returns whether the base pack is installed, which marks a materialized
  instance ontology.
  """
  @spec installed?() :: boolean()
  def installed? do
    SchemaPack
    |> where([pack], pack.name == @base_pack)
    |> Repo.exists?()
  end

  @doc """
  Installs the selected packs plus the base pack in one transaction.

  Already-installed packs are rejected. The merge validation runs over the
  union of installed manifests and new seeds, so a later industry add-on
  passes the same rules as the setup-time selection. Registered types keep
  their first declaring pack; new packs can only add subtype suggestions to
  them.
  """
  @spec install_packs([String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def install_packs(names, opts \\ []) when is_list(names) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, ordered} <- normalize_selection(names) do
      repo.transact(fn repo ->
        installed = repo.all(SchemaPack |> lock("FOR UPDATE"))
        installed_names = MapSet.new(installed, & &1.name)

        new_names = Enum.reject(ordered, &MapSet.member?(installed_names, &1))

        case ensure_new_packs(ordered, installed_names, new_names) do
          {:already_installed, names} ->
            {:ok, %{status: :already_installed, installed: names}}

          :ok ->
            with {:ok, seeds} <- load_seeds(new_names),
                 all_manifests =
                   Enum.map(installed, & &1.manifest) ++ Enum.map(seeds, & &1.manifest),
                 {:ok, merged} <- merge_manifests(all_manifests) do
              materialize(repo, seeds, merged)
            end
        end
      end)
    end
  end

  # Selection and seed loading

  defp normalize_selection(names) do
    names = Enum.map(names, &to_string/1)

    case Enum.reject(names, &(&1 in [@base_pack | @industry_packs])) do
      [] -> {:ok, [@base_pack | Enum.uniq(names) -- [@base_pack]]}
      unknown -> {:error, {:unknown_packs, unknown}}
    end
  end

  defp ensure_new_packs(_ordered, _installed_names, [_ | _]), do: :ok

  # A selection that is already fully installed is a converged state, not an
  # error: completion retries run inside a caller transaction that an inner
  # error result would poison.
  defp ensure_new_packs(ordered, installed_names, []) do
    if Enum.all?(ordered, &MapSet.member?(installed_names, &1)),
      do: {:already_installed, ordered},
      else: :ok
  end

  defp load_seeds(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case load_seed(name) do
        {:ok, seed} -> {:cont, {:ok, [seed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, seeds} -> {:ok, Enum.reverse(seeds)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_manifest(name, raw) do
    with {:ok, parsed} <- YamlElixir.read_from_string(raw),
         :ok <- validate_manifest_shape(name, parsed) do
      {:ok, parsed}
    end
  end

  defp validate_manifest_shape(name, %{"api_version" => @api_version, "name" => name} = manifest) do
    cond do
      not is_binary(manifest["version"]) or manifest["version"] == "" ->
        {:error, :missing_version}

      name != @base_pack and manifest["extends"] != @base_pack ->
        {:error, :industry_pack_must_extend_general}

      name == @base_pack and manifest["extends"] not in [nil, "null"] ->
        {:error, :base_pack_must_not_extend}

      true ->
        validate_declarations(manifest)
    end
  end

  defp validate_manifest_shape(_name, %{"api_version" => other}) when other != @api_version,
    do: {:error, {:unsupported_api_version, other}}

  defp validate_manifest_shape(name, _manifest), do: {:error, {:manifest_name_mismatch, name}}

  defp validate_declarations(manifest) do
    types = manifest["page_types"] || []
    links = manifest["link_types"] || []
    domains = manifest["calibration_domains"] || []
    extensions = manifest["subtype_extensions"] || []

    with :ok <- validate_all(types, &validate_type_declaration/1),
         :ok <- validate_all(links, &validate_link_declaration/1),
         :ok <- validate_all(domains, &validate_domain_declaration/1),
         :ok <- validate_all(extensions, &validate_extension_declaration/1) do
      :ok
    end
  end

  defp validate_all(items, validator) when is_list(items) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case validator.(item) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_all(_items, _validator), do: {:error, :invalid_declaration_list}

  defp validate_type_declaration(
         %{"name" => name, "primitive" => primitive, "slug_prefix" => prefix} = type
       )
       when is_binary(name) and name != "" and is_binary(prefix) and prefix != "" do
    subtypes = Map.get(type, "subtypes", [])

    cond do
      primitive not in @primitives ->
        {:error, {:invalid_primitive, name, primitive}}

      not String.ends_with?(prefix, "/") ->
        {:error, {:invalid_slug_prefix, name, prefix}}

      not (is_list(subtypes) and Enum.all?(subtypes, &is_binary/1)) ->
        {:error, {:invalid_subtypes, name}}

      not is_boolean(Map.get(type, "extractable", false)) ->
        {:error, {:invalid_extractable, name}}

      not is_boolean(Map.get(type, "expert_routing", false)) ->
        {:error, {:invalid_expert_routing, name}}

      true ->
        :ok
    end
  end

  defp validate_type_declaration(type), do: {:error, {:invalid_type_declaration, type}}

  defp validate_link_declaration(%{"name" => name} = link) when is_binary(name) and name != "" do
    case Map.get(link, "inverse") do
      nil -> :ok
      inverse when is_binary(inverse) and inverse != "" -> :ok
      _invalid -> {:error, {:invalid_link_inverse, name}}
    end
  end

  defp validate_link_declaration(link), do: {:error, {:invalid_link_declaration, link}}

  defp validate_domain_declaration(%{"name" => name, "aggregator" => aggregator})
       when is_binary(name) and name != "" and is_binary(aggregator) and aggregator != "",
       do: :ok

  defp validate_domain_declaration(domain), do: {:error, {:invalid_domain_declaration, domain}}

  defp validate_extension_declaration(%{"type" => type, "add" => add})
       when is_binary(type) and type != "" and is_list(add) do
    if Enum.all?(add, &is_binary/1), do: :ok, else: {:error, {:invalid_subtype_extension, type}}
  end

  defp validate_extension_declaration(extension),
    do: {:error, {:invalid_subtype_extension_declaration, extension}}

  # Merge rules

  # Merges manifests in installation order into one consistent declaration
  # set: types identical-or-error with subtype union, unique slug prefixes,
  # identical-or-error links and calibration domains, and subtype extensions
  # resolved against the merged type set.
  defp merge_manifests(manifests) do
    with {:ok, types} <- merge_types(manifests),
         {:ok, types} <- apply_subtype_extensions(types, manifests),
         :ok <- validate_unique_prefixes(types),
         {:ok, links} <- merge_named(manifests, "link_types", &link_signature/1),
         {:ok, domains} <- merge_named(manifests, "calibration_domains", &domain_signature/1) do
      {:ok, %{types: types, link_types: links, calibration_domains: domains}}
    end
  end

  defp merge_types(manifests) do
    Enum.reduce_while(manifests, {:ok, %{}}, fn manifest, {:ok, acc} ->
      pack_name = manifest["name"]

      manifest
      |> Map.get("page_types", [])
      |> Enum.reduce_while({:ok, acc}, fn type, {:ok, acc} ->
        name = type["name"]

        case Map.get(acc, name) do
          nil ->
            merged = %{
              "name" => name,
              "primitive" => type["primitive"],
              "slug_prefix" => type["slug_prefix"],
              "subtypes" => Map.get(type, "subtypes", []),
              "extractable" => Map.get(type, "extractable", false),
              "expert_routing" => Map.get(type, "expert_routing", false),
              "pack_name" => pack_name
            }

            {:cont, {:ok, Map.put(acc, name, merged)}}

          existing ->
            if same_type_core?(existing, type) do
              merged =
                Map.update!(existing, "subtypes", fn subtypes ->
                  Enum.uniq(subtypes ++ Map.get(type, "subtypes", []))
                end)

              {:cont, {:ok, Map.put(acc, name, merged)}}
            else
              {:halt, {:error, {:type_declaration_conflict, name, pack_name}}}
            end
        end
      end)
      |> case do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp same_type_core?(existing, type) do
    existing["primitive"] == type["primitive"] and
      existing["slug_prefix"] == type["slug_prefix"] and
      existing["extractable"] == Map.get(type, "extractable", false) and
      existing["expert_routing"] == Map.get(type, "expert_routing", false)
  end

  defp apply_subtype_extensions(types, manifests) do
    manifests
    |> Enum.flat_map(fn manifest ->
      manifest
      |> Map.get("subtype_extensions", [])
      |> Enum.map(&{manifest["name"], &1})
    end)
    |> Enum.reduce_while({:ok, types}, fn {pack_name, extension}, {:ok, acc} ->
      type_name = extension["type"]

      case Map.get(acc, type_name) do
        nil ->
          {:halt, {:error, {:subtype_extension_unknown_type, type_name, pack_name}}}

        type ->
          merged =
            Map.update!(type, "subtypes", fn subtypes ->
              Enum.uniq(subtypes ++ extension["add"])
            end)

          {:cont, {:ok, Map.put(acc, type_name, merged)}}
      end
    end)
  end

  defp validate_unique_prefixes(types) do
    types
    |> Map.values()
    |> Enum.group_by(& &1["slug_prefix"])
    |> Enum.find(fn {_prefix, declared} -> length(declared) > 1 end)
    |> case do
      nil ->
        :ok

      {prefix, declared} ->
        {:error, {:slug_prefix_conflict, prefix, Enum.map(declared, & &1["name"])}}
    end
  end

  defp merge_named(manifests, key, signature) do
    Enum.reduce_while(manifests, {:ok, %{}}, fn manifest, {:ok, acc} ->
      pack_name = manifest["name"]

      manifest
      |> Map.get(key, [])
      |> Enum.reduce_while({:ok, acc}, fn item, {:ok, acc} ->
        name = item["name"]

        case Map.get(acc, name) do
          nil ->
            {:cont, {:ok, Map.put(acc, name, Map.put(item, "pack_name", pack_name))}}

          existing ->
            if signature.(existing) == signature.(item) do
              {:cont, {:ok, acc}}
            else
              {:halt, {:error, {:declaration_conflict, key, name, pack_name}}}
            end
        end
      end)
      |> case do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp link_signature(link), do: {link["name"], Map.get(link, "inverse")}
  defp domain_signature(domain), do: {domain["name"], domain["aggregator"]}

  # Materialization

  defp materialize(repo, seeds, merged) do
    now = DateTime.utc_now(:microsecond)

    with :ok <- insert_pack_rows(repo, seeds, now),
         :ok <- upsert_type_rows(repo, merged.types, now),
         :ok <- insert_link_rows(repo, merged.link_types, now),
         :ok <- insert_domain_rows(repo, merged.calibration_domains, now) do
      {:ok,
       %{
         installed: Enum.map(seeds, & &1.manifest["name"]),
         types: map_size(merged.types),
         link_types: map_size(merged.link_types),
         calibration_domains: map_size(merged.calibration_domains)
       }}
    end
  end

  defp insert_pack_rows(repo, seeds, now) do
    rows =
      Enum.map(seeds, fn seed ->
        %{
          id: UUIDv7.autogenerate(),
          name: seed.manifest["name"],
          version: seed.manifest["version"],
          content_hash: seed.content_hash,
          manifest: seed.manifest,
          installed_at: now
        }
      end)

    repo.insert_all(SchemaPack, rows)
    :ok
  end

  # Types already registered by an earlier install or a promotion keep their
  # row and first declaring pack; a new pack can only widen their subtype
  # suggestions. New names insert with the merged declaration.
  defp upsert_type_rows(repo, types, now) do
    existing =
      SchemaType
      |> repo.all()
      |> Map.new(&{&1.name, &1})

    Enum.reduce_while(types, :ok, fn {name, type}, :ok ->
      case Map.get(existing, name) do
        nil ->
          row = %SchemaType{
            id: UUIDv7.autogenerate(),
            name: name,
            primitive: type["primitive"],
            slug_prefix: type["slug_prefix"],
            subtypes: type["subtypes"],
            extractable: type["extractable"],
            expert_routing: type["expert_routing"],
            pack_name: type["pack_name"],
            created_at: now
          }

          case repo.insert(row) do
            {:ok, _row} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        registered ->
          if registered.primitive == type["primitive"] and
               registered.slug_prefix == type["slug_prefix"] and
               registered.extractable == type["extractable"] and
               registered.expert_routing == type["expert_routing"] do
            subtypes = Enum.uniq(registered.subtypes ++ type["subtypes"])

            case repo.update(Ecto.Changeset.change(registered, subtypes: subtypes)) do
              {:ok, _row} -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          else
            {:halt, {:error, {:registered_type_conflict, name}}}
          end
      end
    end)
  end

  defp insert_link_rows(repo, links, now) do
    existing = repo.all(SchemaLinkType |> select([link], link.name)) |> MapSet.new()

    rows =
      links
      |> Map.values()
      |> Enum.reject(&MapSet.member?(existing, &1["name"]))
      |> Enum.map(fn link ->
        %{
          id: UUIDv7.autogenerate(),
          name: link["name"],
          inverse: Map.get(link, "inverse"),
          pack_name: link["pack_name"],
          created_at: now
        }
      end)

    repo.insert_all(SchemaLinkType, rows)
    :ok
  end

  defp insert_domain_rows(repo, domains, now) do
    existing = repo.all(SchemaCalibrationDomain |> select([domain], domain.name)) |> MapSet.new()

    rows =
      domains
      |> Map.values()
      |> Enum.reject(&MapSet.member?(existing, &1["name"]))
      |> Enum.map(fn domain ->
        %{
          id: UUIDv7.autogenerate(),
          name: domain["name"],
          aggregator: domain["aggregator"],
          pack_name: domain["pack_name"],
          created_at: now
        }
      end)

    repo.insert_all(SchemaCalibrationDomain, rows)
    :ok
  end

  defp seeds_root do
    Application.app_dir(:ankole, "priv/brain/schema_packs")
  end
end
