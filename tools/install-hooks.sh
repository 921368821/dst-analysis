#!/usr/bin/env bash
#==============================================================================
# install-hooks.sh —— 把仓库自带的钩子装进 .git/hooks（L4）
#
# 为什么钩子的**内容**要放在仓库里（tools/pre-commit.sh）而不是直接写进
# `.git/hooks/pre-commit`：
#   `.git/` 不进版本库 ⇒ 写在里面的钩子**换台机器就没了**，也没人 review 得到。
#   仓库里存脚本 + 这里只做「装一个转发壳」，克隆后跑一次即可。
#
# 用法：bash tools/install-hooks.sh
#==============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
[ -d .git ] || { echo "✘ 当前目录不是 git 仓库根：$ROOT" >&2; exit 1; }

cat > .git/hooks/pre-commit <<'HOOK'
#!/usr/bin/env bash
# 自动生成 —— 真正的逻辑在 tools/pre-commit.sh（入库、可 review）
exec bash "$(git rev-parse --show-toplevel)/tools/pre-commit.sh"
HOOK
chmod +x .git/hooks/pre-commit
echo "✔ 已安装 .git/hooks/pre-commit → tools/pre-commit.sh"
echo "  绕过：SKIP_PRECOMMIT=1 git commit ...（记得在提交信息里写原因）"
