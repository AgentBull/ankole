#!/bin/sh
set -eu

answer=/app/answer.md
artifact_verified=0
stance_preserved=0
claim_fidelity=0
no_false_balance=0

if [ -s "$answer" ]; then
  artifact_verified=1
  if grep -Fq '独家' "$answer" && grep -Fq '衍生数据' "$answer" && grep -Eq '抽取|清洗|加工|管线|pipeline|数据血缘' "$answer"; then
    stance_preserved=1
  fi
  if ! grep -Eq '缺乏证据|缺乏记录|没有证据|没有记录|无法确认|有待核实|尚未证明|逐项谈定|管理层口径|据称|需要核实|需要确认' "$answer"; then
    claim_fidelity=1
    no_false_balance=1
  fi
fi

reward=$((artifact_verified * stance_preserved * claim_fidelity * no_false_balance))
mkdir -p /logs/verifier/evidence/outcome
printf '{"reward":%s,"stance_preserved":%s,"claim_fidelity":%s,"no_false_balance":%s,"artifact_verified":%s}\n' \
  "$reward" "$stance_preserved" "$claim_fidelity" "$no_false_balance" "$artifact_verified" \
  > /logs/verifier/reward.json
printf '{"answer_present":%s}\n' "$artifact_verified" \
  > /logs/verifier/evidence/outcome/checks.json
if [ -f "$answer" ]; then
  cp "$answer" /logs/verifier/evidence/outcome/answer.md
fi
