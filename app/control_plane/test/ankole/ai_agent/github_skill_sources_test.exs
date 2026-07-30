defmodule Ankole.AIAgent.GitHubSkillSourcesTest do
  use ExUnit.Case, async: true

  @github_root Path.expand("../../../../library/agent-plugins/github", __DIR__)

  test "the public GitHub webhook Skill owns the complete external lifecycle" do
    skill = File.read!(Path.join([@github_root, "skills", "github-webhooks", "SKILL.md"]))
    normalized_skill = String.replace(skill, ~r/\s+/, " ")

    assert skill =~ "create-webhook-cli"
    assert skill =~ "check_back_later"
    assert normalized_skill =~ "GitHub then sends `ping`"
    assert normalized_skill =~ "`create-webhook-cli --help` is the authoritative guide"
    assert normalized_skill =~ "Read it before the first `create-webhook-cli` call"
    assert normalized_skill =~ "GitHub does not automatically retry failed deliveries"
    assert normalized_skill =~ "GitHub hook is deleted first"
    assert skill =~ "cancel-webhook-cli"
    assert normalized_skill =~ "one repository hook"
    assert skill =~ "1 MiB"
    assert normalized_skill =~ "old endpoint and checkback are cancelled before one replacement"
    # The generic capability contract lives in `create-webhook-cli --help`, not here.
    refute normalized_skill =~ "idempotent"
    refute normalized_skill =~ "wake-up capability"
    refute skill =~ "EventBridge"
    refute skill =~ "Flink"
  end

  test "the webhook API reference uses repository-native create, delivery, redelivery, and delete calls" do
    reference =
      File.read!(
        Path.join([
          @github_root,
          "skills",
          "github-webhooks",
          "references",
          "repository-webhook-api.md"
        ])
      )

    assert reference =~ "\"repos/$GH_OWNER/$GH_REPO/hooks\""
    assert reference =~ "deliveries/$DELIVERY_ID/attempts"
    assert reference =~ "--method DELETE"
    assert reference =~ "content_type: \"json\""
    assert reference =~ "insecure_ssl: \"0\""
    assert reference =~ "callback_matches"
    assert reference =~ "del(.config.url)"
    assert reference =~ "del(.url, .request.payload.hook.config.url)"
    refute reference =~ ".[] | {id, active, events, config, last_response}"
    refute reference =~ "secret:"
  end

  test "the public Skills use the Ankole GitHub CLI credential boundary" do
    source_files =
      @github_root
      |> Path.join("skills/**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)

    corpus = Enum.map_join(source_files, "\n", &File.read!/1)
    normalized_corpus = String.replace(corpus, ~r/\s+/, " ")

    assert corpus =~
             "source /repo/app/library/agent-plugins/github/skills/github-auth/scripts/gh-env.sh"

    assert normalized_corpus =~ "helper is the complete authentication boundary"
    assert normalized_corpus =~ "stop GitHub work"
    assert normalized_corpus =~ "can disclose secrets"
    refute corpus =~ ~s(Authorization: token $GITHUB_TOKEN)
    refute corpus =~ "read_file"
    refute corpus =~ "git add ."
  end

  test "the internal image no longer overlays the public GitHub package" do
    dockerfile =
      @github_root
      |> Path.join("../../../control_plane/Dockerfile.internal")
      |> Path.expand()
      |> File.read!()

    refute dockerfile =~ "internals/agent-plugins"
  end
end
