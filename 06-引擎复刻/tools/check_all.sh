#!/usr/bin/env bash
#==============================================================================
# check_all.sh —— **核对三件套的总入口**（T56 / T62）
#==============================================================================
# 为什么要有它
#   三个核对工具各自独立，很容易**只跑其中一个**就以为「都绿了」。
#   今天这种情况发生过多次（多次靠人手动跑齐，或在收尾时漏跑 verify_report）。
#   ⇒ 一个入口跑齐，并且**汇总结论**（任一项红 ⇒ 整体红、退出码非 0）。
#
# 用法
#   bash tools/check_all.sh            # 全部（含 verify_report，约 2~3 分钟）
#   bash tools/check_all.sh --fast     # 跳过 verify_report（约 10 秒）
#   bash tools/check_all.sh --json     # **只把 JSON 打到 stdout**，人类可读输出转 stderr
#                                      # （便于接进别的自动化；T62）
#   可组合：`--fast --json`
#
# JSON 形态（--json 时）
#   {"generated_by":"tools/check_all.sh","fast":false,
#    "checks":{"audit_fixes":{"rc":0,"ok":true}, ...},
#    "overall_ok":true}
#
# 退出码
#   0 = 三项全绿 ；1 = 至少一项红
#==============================================================================
set -u
# ★ 先记下绝对路径再 cd：原来在 cd 之后还用 $(dirname "$0")（相对），
#   一旦用绝对路径调用就错位 —— 与本工程记过的「相对 cd 那次」同源。
_HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$_HERE/.." || exit 1

# ★ 解释器由工程根的 tools/env.sh 统一解析（原来硬编码用户目录，搬迁即失效）
. "$_HERE/../../tools/env.sh" || exit 2
FAST=0
JSON=0
for arg in "$@"; do
    case "$arg" in
        --fast) FAST=1 ;;
        --json) JSON=1 ;;
        *) echo "未知参数: $arg" >&2; exit 1 ;;
    esac
done

# --json 时：人类可读输出走 stderr，stdout 只留 JSON
if [ "$JSON" = "1" ]; then
    exec 3>&1        # 保住原 stdout
    exec 1>&2        # 后续所有 echo 都到 stderr
fi

FAILED=0
RC_AF=0; RC_ADN=0; RC_VR=0
note() { printf '\n\033[1m══ %s\033[0m\n' "$1"; }

# ---------- 1. 修复清单 + 特征串质量/自满足/歧义锚点/豁免 ----------
note "1/3  audit_fixes.py（修复清单 + 特征串质量）"
if "$PY" -u tools/audit_fixes.py; then RC_AF=0; else RC_AF=$?; [ "$RC_AF" = "0" ] && RC_AF=1; FAILED=1; fi

# ---------- 2. 全部 md 的数字 / 时间戳 / 类别名 ----------
note "2/3  audit_doc_numbers.py（全部 md 的数字与结构一致性）"
if "$PY" -u tools/audit_doc_numbers.py; then RC_ADN=0; else RC_ADN=$?; [ "$RC_ADN" = "0" ] && RC_ADN=1; FAILED=1; fi

# ---------- 3. 报告关键数字 vs 实跑（慢） ----------
SKIPPED="false"
if [ "$FAST" = "1" ]; then
    SKIPPED="true"
    note "3/3  verify_report.py —— **已跳过**（--fast）"
    echo "  ⚠️ 本次没跑它；正式收尾时请**不带 --fast** 再跑一次。"
else
    note "3/3  verify_report.py（报告关键数字 vs 实跑，约 2 分钟）"
    if "$PY" -u tools/verify_report.py; then RC_VR=0; else RC_VR=$?; [ "$RC_VR" = "0" ] && RC_VR=1; FAILED=1; fi
fi

# ---------- 汇总 ----------
printf '\n'
if [ "$FAILED" = "0" ]; then
    if [ "$FAST" = "1" ]; then
        echo "── 总判定：✔ 已跑的两项全绿（⚠️ verify_report 被跳过） ──"
    else
        echo "── 总判定：✔ 三件套全绿 ──"
    fi
else
    echo "── 总判定：✘ 有红项（见上面各处 ✘ 行） ──"
fi

if [ "$JSON" = "1" ]; then
    ok_bool() { [ "$1" = "0" ] && printf 'true' || printf 'false'; }
    fast_bool() { [ "$FAST" = "1" ] && printf 'true' || printf 'false'; }
    if [ "$SKIPPED" = "true" ]; then
        vr_json='{"rc":0,"ok":true,"skipped":true}'
    else
        vr_json=$(printf '{"rc":%s,"ok":%s,"skipped":false}' "$RC_VR" "$(ok_bool "$RC_VR")")
    fi
    printf '{"generated_by":"tools/check_all.sh","fast":%s,"checks":{' "$(fast_bool)" >&3
    printf '"audit_fixes":{"rc":%s,"ok":%s},' "$RC_AF" "$(ok_bool "$RC_AF")" >&3
    printf '"audit_doc_numbers":{"rc":%s,"ok":%s},' "$RC_ADN" "$(ok_bool "$RC_ADN")" >&3
    printf '"verify_report":%s},' "$vr_json" >&3
    printf '"overall_ok":%s}\n' "$(ok_bool "$FAILED")" >&3
fi

[ "$FAILED" = "0" ] && exit 0 || exit 1
