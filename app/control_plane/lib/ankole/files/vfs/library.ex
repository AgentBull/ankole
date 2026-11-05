defmodule Ankole.Files.Vfs.Library do
  @moduledoc "Read-only Drive projections selected solely by the current Agent identity."
  alias Ankole.AIAgent.Library, as: AgentLibrary
  alias Ankole.AIAgent.Library.{Contracts, Skills}
  alias Ankole.Files

  def roots(scope) do
    {:ok, contracts} = Contracts.effective(scope.actor.principal.uid)

    [
      directory("Skills", [], "skills")
      | Enum.map([{"AGENTS.md", "agents"}, {"DESIGN.md", "design"}], fn {name, slot} ->
          text(name, contracts[slot]["content"], [name])
        end)
    ]
  end

  def resolve(scope, ["Skills" | parts]), do: skill_path(scope, parts)

  def resolve(scope, [name]) when name in ["AGENTS.md", "DESIGN.md"] do
    {:ok, Enum.find(roots(scope), &(&1.name == name))}
  end

  def resolve(_, _), do: {:error, :not_found}

  def children(scope, %{library_path: []}) do
    with {:ok, skills} <-
           AgentLibrary.enabled_skills_for_agent(scope.actor.principal.uid,
             runtime_projection: scope[:runtime_projection],
             sync: false
           ),
         do:
           {:ok,
            Enum.map(skills, &directory(&1["skill_name"], [&1["skill_name"]], &1["skill_name"]))}
  end

  def children(scope, %{library_path: [slug | parts]}) do
    with {:ok, skill} <- enabled_skill(scope, slug) do
      prefix = if parts == [], do: "", else: Enum.join(parts, "/") <> "/"
      files = Skills.files(skill.id)
      paths = ["SKILL.md" | Enum.map(files, & &1.relative_path)]

      paths
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.map(&(String.replace_prefix(&1, prefix, "") |> String.split("/") |> hd()))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&package_path(skill, parts ++ [&1], files))
      |> Ankole.Attrs.collect_results()
    end
  end

  defp enabled_skill(scope, slug) do
    case AgentLibrary.enabled_skill(scope.actor.principal.uid, slug,
           runtime_projection: scope[:runtime_projection],
           sync: false
         ) do
      {:error, reason} when reason in [:skill_not_found, :skill_not_enabled] ->
        {:error, :not_found}

      result ->
        result
    end
  end

  defp skill_path(scope, [slug | parts]) do
    with {:ok, skill} <- enabled_skill(scope, slug) do
      package_path(skill, parts, Skills.files(skill.id))
    end
  end

  defp skill_path(_, []), do: {:ok, directory("Skills", [], "skills")}

  defp package_path(skill, parts, files) do
    slug = skill.slug
    path = Enum.join(parts, "/")

    cond do
      path == "" ->
        {:ok, directory(slug, [slug], "#{skill.id}:#{skill.revision}")}

      path == "SKILL.md" ->
        {:ok, text("SKILL.md", skill.manifest_markdown, [slug, "SKILL.md"])}

      true ->
        case Enum.find(files, &(&1.relative_path == path)) do
          %{} = file ->
            with {:ok, object} <- Files.fetch_object(file.object_id) do
              {:ok,
               %{
                 node: nil,
                 name: List.last(parts),
                 kind: :virtual_file,
                 library_path: [slug | parts],
                 read_only: true,
                 mode: if(Bitwise.band(file.mode, 0o111) > 0, do: 0o555, else: 0o444),
                 etag: "\"skill:#{skill.id}:#{file.object_id}\"",
                 size: object.size,
                 fingerprint: "sha256:" <> Base.encode16(object.sha256, case: :lower),
                 content_type: file.content_type,
                 modified: file.updated_at,
                 content: {:object, object.id, object.size}
               }}
            end

          nil ->
            if Enum.any?(
                 files,
                 &String.starts_with?(&1.relative_path, path <> "/")
               ),
               do:
                 {:ok,
                  directory(
                    List.last(parts),
                    [slug | parts],
                    "#{skill.id}:#{skill.revision}:#{path}"
                  )},
               else: {:error, :not_found}
        end
    end
  end

  defp directory(name, path, id),
    do: %{
      node: nil,
      name: name,
      kind: :virtual_directory,
      library_path: path,
      read_only: true,
      mode: 0o555,
      etag: "\"#{id}\"",
      size: 0,
      content_type: "httpd/unix-directory",
      modified: DateTime.from_unix!(0)
    }

  defp text(name, bytes, path),
    do: %{
      node: nil,
      name: name,
      kind: :virtual_file,
      library_path: path,
      read_only: true,
      mode: 0o444,
      etag: "\"#{Ankole.Kernel.vfs_fingerprint(bytes)}\"",
      fingerprint: Ankole.Kernel.vfs_fingerprint(bytes),
      size: byte_size(bytes),
      content_type: "text/markdown; charset=utf-8",
      modified: DateTime.from_unix!(0),
      content: {:bytes, bytes}
    }
end
