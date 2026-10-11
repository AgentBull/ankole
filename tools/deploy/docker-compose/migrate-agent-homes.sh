#!/bin/sh
# Copy pooled Agent Homes before the control plane can create any Worker.
# Remove this service only when upgrades from pooled Workers are no longer supported.
set -eu

legacy=${LEGACY_VOLUME:?}
project=${COMPOSE_PROJECT:?}
installation=${WORKER_INSTALLATION:?}
provider=${WORKER_PROVIDER:?}
image=${MIGRATION_IMAGE:?}

# A failed daemon request is not evidence that the old volume is absent.
volumes=$(docker volume ls --format '{{.Name}}')
found=false
for volume in $volumes; do
  if [ "$volume" = "$legacy" ]; then found=true; break; fi
done
if [ "$found" = false ]; then exit 0; fi

# Old Compose services become orphans when the service is removed from YAML.
# Stop all containers that mount the old volume, including paused containers.
containers=$(docker ps -aq --filter "volume=$legacy")
for container in $containers; do
  if [ "$(docker inspect --format '{{.State.Paused}}' "$container")" = true ]; then
    docker unpause "$container"
  fi
  docker stop --time 60 "$container"
  test "$(docker inspect --format '{{.State.Running}}' "$container")" = false
done

# The old release did not remove the Home of a deleted Agent. Copy only the
# Homes of Agents that still exist, so a new Agent with the same UID starts
# with an empty Home. The skipped directories stay in the old volume.
postgres=$(docker ps -q --filter "label=com.docker.compose.project=$project" \
  --filter "label=com.docker.compose.service=postgresql")
test -n "$postgres"
existing=$(docker exec "$postgres" psql -U ankole -d ankole -XAtc 'SELECT uid FROM agents')

agents=$(docker run --rm --network none --entrypoint sh \
  --mount "type=volume,source=$legacy,target=/source" "$image" -ec '
    for directory in /source/*; do
      [ -d "$directory" ] || continue
      agent=${directory##*/}
      printf "%s\n" "$agent"
    done
  ')

for agent in $agents; do
  # Agent UIDs cannot contain shell separators, whitespace, or path components.
  if ! printf '%s\n' "$agent" | grep -Eq '^[a-z0-9][a-z0-9._-]{0,95}$'; then
    echo "Invalid Agent directory: $agent" >&2
    exit 1
  fi
  if ! printf '%s\n' "$existing" | grep -Fxq "$agent"; then
    printf 'Skipped the Home of a deleted Agent: %s\n' "$agent"
    continue
  fi
  # Keep this name equal to AgentWorkers.ProviderKind.storage_name/2.
  hash=$(printf '%s' "$agent" | sha256sum | cut -c1-16)
  target="ankole-$installation-$hash"
  marker=$(docker run --rm --network none --entrypoint sh \
    --mount "type=volume,source=$legacy,target=/source" "$image" -ec '
      marker=/source/.ankole-worker-provider-migration/$1
      if [ -f "$marker" ]; then cat "$marker"; fi
    ' -- "$agent")
  if [ -n "$marker" ]; then
    test "$marker" = "$target"
    # An Agent may have been deleted since migration. Do not create it again.
    continue
  fi

  docker volume create --driver local \
    --label "ankole.installation=$installation" \
    --label "ankole.provider=$provider" \
    --label "ankole.agent-uid=$agent" "$target" >/dev/null
  test "$(docker volume inspect --format '{{.Driver}}' "$target")" = local
  test "$(docker volume inspect --format '{{len .Options}}' "$target")" = 0
  test "$(docker volume inspect --format '{{index .Labels "ankole.installation"}}' "$target")" = "$installation"
  test "$(docker volume inspect --format '{{index .Labels "ankole.provider"}}' "$target")" = "$provider"
  test "$(docker volume inspect --format '{{index .Labels "ankole.agent-uid"}}' "$target")" = "$agent"
  docker run --rm --network none --entrypoint sh \
    --mount "type=volume,source=$legacy,target=/source" \
    --mount "type=volume,source=$target,target=/target" "$image" -ec '
      cp -a "/source/$1/." /target/
      chown -R 1000:1000 /target
      sync
      mkdir -p /source/.ankole-worker-provider-migration
      marker=/source/.ankole-worker-provider-migration/$1
      printf "%s\n" "$2" > "$marker.tmp"
      mv "$marker.tmp" "$marker"
      sync
    ' -- "$agent" "$target"
  printf 'Migrated Agent Home: %s\n' "$agent"
done
