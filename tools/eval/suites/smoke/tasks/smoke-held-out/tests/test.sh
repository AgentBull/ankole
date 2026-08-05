#!/bin/sh
set -eu

mkdir -p /logs/verifier/evidence/outcome
if [ -f /app/result.txt ] && [ "$(cat /app/result.txt)" = 'held-out-ok' ]; then
  printf '%s\n' '{"reward":1,"artifact_verified":1}' > /logs/verifier/reward.json
  printf '%s\n' '{"verified":true}' > /logs/verifier/evidence/outcome/result.json
else
  printf '%s\n' '{"reward":0,"artifact_verified":0}' > /logs/verifier/reward.json
  printf '%s\n' '{"verified":false}' > /logs/verifier/evidence/outcome/result.json
fi
