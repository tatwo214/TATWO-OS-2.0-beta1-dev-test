#!/bin/bash
# 用法：room-guard.sh <repo> <base> <head> <allow 檔> <產品淨行數上限>
# 合併前的硬邊界檢查（使用者 10-04「一定要給他明確邊界」）：白名單外有改動或產品淨行數超過上限＝GUARD FAIL，直接退件。
# allow 檔：一行一個路徑樣式（bash 萬用字元，例 App/Sources/Tatwo2/TAP/ChatGPTSpace.swift、tests/w208-*）；以 ! 開頭的是禁區；# 開頭是註解。
# 產品程式＝tests/ 與 *Acceptance.swift 以外的檔。
R="$1"; B="$2"; H="$3"; A="$4"; CAP="$5"
[ -d "$R" ] && [ -f "$A" ] && [ -n "$CAP" ] || { echo "用法：room-guard.sh <repo> <base> <head> <allow 檔> <產品淨行數上限>"; exit 2; }
allow=(); deny=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"; line="$(echo "$line" | sed 's/[[:space:]]*$//')"; [ -z "$line" ] && continue
  case "$line" in !*) deny+=("${line#!}");; *) allow+=("$line");; esac
done < "$A"
fail=0; outside=(); denied=(); pa=0; pd=0
while IFS=$'\t' read -r add del path; do
  [ -z "$path" ] && continue
  ok=0; for g in "${allow[@]}"; do [[ "$path" == $g ]] && ok=1 && break; done
  for g in "${deny[@]}"; do [[ "$path" == $g ]] && { denied+=("$path"); ok=0; }; done
  [ $ok = 1 ] || outside+=("$path")
  case "$path" in tests/*|*Acceptance.swift) ;; *) [ "$add" != "-" ] && pa=$((pa+add)) && pd=$((pd+del));; esac
done < <(git -C "$R" diff --numstat "$B" "$H")
net=$((pa-pd))
echo "產品程式 +${pa} -${pd} 淨 ${net}（上限 ${CAP}）"
if [ ${#denied[@]} -gt 0 ]; then fail=1; echo "禁區有改動："; printf '  %s\n' "${denied[@]}"; fi
if [ ${#outside[@]} -gt 0 ]; then fail=1; echo "白名單外的改動："; printf '  %s\n' "${outside[@]}" | sort -u; fi
[ "$net" -gt "$CAP" ] && { fail=1; echo "產品淨行數 ${net} 超過上限 ${CAP}"; }
[ $fail = 0 ] && echo "GUARD PASS" || echo "GUARD FAIL"
exit $fail
