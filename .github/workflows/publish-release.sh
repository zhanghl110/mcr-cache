#!/usr/bin/env bash
# =============================================================================
# publish-release.sh —— 把 dist/ 下的基线镜像产物发布到 GitHub Release
#
# 在哪跑：与 build-base.sh 同一环境（Actions runner 或任何装了 gh 的机器）
# 前置：dist/base.tar.gz 与 dist/digest.txt 已由 build-base.sh 生成
# 认证：环境变量 GH_TOKEN 或 GITHUB_TOKEN（Actions 里用 ${{ github.token }}）
#
# 用法：
#   GH_TOKEN=ghp_xxx bash publish-release.sh
#   REL_TAG=dotnet-base-10.0-mcr bash publish-release.sh     # 覆盖同名 Release 的资产
#
# 设计要点：Release tag 固定可预测（不带 run_number），内网下载 URL 才稳定
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

DIST="${DIST:-dist}"
REL_TAG="${REL_TAG:-dotnet-base-10.0-mcr}"
TITLE="${TITLE:-ems/dotnet-base 10.0-mcr（官方 aspnet 10.0 + 补齐层）}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()  { printf '\033[32m[OK] %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m[FAIL] %s\033[0m\n' "$*" >&2; exit 1; }

command -v gh >/dev/null || die "未找到 gh CLI（Actions 自带；本机请装 GitHub CLI）"
[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ] || die "缺少 GH_TOKEN 或 GITHUB_TOKEN"
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

[ -f "$DIST/base.tar.gz" ] || die "$DIST/base.tar.gz 不存在，先跑 build-base.sh"
[ -f "$DIST/digest.txt" ]  || die "$DIST/digest.txt 不存在，先跑 build-base.sh"

say "校验本地产物"
( cd "$DIST" && sha256sum -c base.tar.gz.sha256 ) || die "本地 base.tar.gz 与 .sha256 不一致"

say "准备 Release $REL_TAG"
if gh release view "$REL_TAG" >/dev/null 2>&1; then
  echo "Release 已存在，本次覆盖资产（overwrite）"
else
  {
    echo "ems/dotnet-base:10.0-mcr —— 官方 mcr.microsoft.com/dotnet/aspnet:10.0 + 补齐层"
    echo ""
    echo '```'
    cat "$DIST/digest.txt"
    echo '```'
    echo ""
    echo "内网导入："
    echo '```bash'
    echo "REPO=${GITHUB_REPOSITORY:-<owner>/<repo>} REL=${REL_TAG} bash load-base.sh"
    echo '```'
    echo ""
    echo "基线约束：默认用户 root（业务 Dockerfile 末尾自行切 appuser 1654）；"
    echo "含 libfontconfig1 / libfreetype6 / libgssapi-krb5-2 / curl；业务侧只改 FROM 一行。"
  } > /tmp/release-notes.md
  gh release create "$REL_TAG" --title "$TITLE" --notes-file /tmp/release-notes.md
fi

say "上传资产"
FILES=("$DIST/base.tar.gz" "$DIST/base.tar.gz.sha256" "$DIST/digest.txt")
shopt -s nullglob
for f in "$DIST"/base.part-* "$DIST"/base.parts.sha256; do FILES+=("$f"); done
shopt -u nullglob
gh release upload "$REL_TAG" "${FILES[@]}" --clobber

say "发布完成"
gh release view "$REL_TAG" --json name,tagName,assets \
  --template '{{.tagName}}  {{.name}}{{"\n"}}{{range .assets}}  {{.name}}  {{.size}} bytes{{"\n"}}{{end}}'
echo
echo "内网下载入口（URL 固定可预测）："
echo "  https://github.com/${GITHUB_REPOSITORY:-<owner>/<repo>}/releases/download/${REL_TAG}/base.tar.gz"
