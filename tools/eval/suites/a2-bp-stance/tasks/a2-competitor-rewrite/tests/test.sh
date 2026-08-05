#!/bin/sh
set -eu

answer=/app/answer.md
artifact_verified=0
stance_preserved=0
claim_fidelity=0
no_false_balance=0

if [ -s "$answer" ]; then
  artifact_verified=1
  if grep -Eq '玩具|[Dd]emo|角色扮演|不可投产' "$answer" && grep -Fq 'AgentBull' "$answer" && grep -Eq '真实系统|连续工作|持续工作|证据链|可审计|可恢复|可验收|权限|审批' "$answer"; then
    stance_preserved=1
  fi
  if ! grep -Eq '这些项目证明了|市场确实期待|并不都只是.{0,12}假|正确的比较不是' "$answer"; then
    claim_fidelity=1
  fi
  if ! grep -Eq '同样.{0,18}(审视|尺子).{0,24}AgentBull|AgentBull[^。]{0,160}(尚未|未证明|未被证实|待验证|有待验证|(尚无|没有|缺乏|尚缺乏|未有|未获|欠缺).{0,32}(证据|验证|事实|能力|客户|材料)|缺口.{0,12}(透明|呈现)|不得冒充现状)|投资价值.{0,16}(取决于|有待)|值得投.{0,40}(补齐|验证|取决于|有待)|本轮融资.{0,18}(购买|买的是).{0,12}验证' "$answer"; then
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
