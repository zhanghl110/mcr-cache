#!/usr/bin/env bash
# =============================================================================
# load-base.sh —— 内网侧：取回基线镜像 → 校验 → 导入 → 契约校验
#
# 两种取法（任选其一）：
#   1) 从 GitHub Release 下载（推荐，URL 固定可预测）
#      REPO=owner/repo bash load-base.sh
#      REPO=owner/repo REL=dotnet-base-10.0-mcr TAR=base.tar.gz bash load-base.sh
#   2) 用已下载好的本地包（内网已有文件时，省 100MB 重传）
#      TAR=/app/ems/mcr-cache/base.tar.gz bash load-base.sh
#
# 行为：
#   - 校验 sha256（.sha256 与包在同目录或同 Release）
#   - 导入前把同名镜像备份为 <repo>:pre-import-<时间戳>（不删旧，保留回退）
#   - docker load 后调用 verify-base.sh 做层指纹 + 契约校验
#
# 可覆盖变量：REPO / REL / TAR / IMG / DL_DIR / FORCE
# 退出码：0 通过；1 失败；2 通过但有告警（不影响使用）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

REPO="${REPO:-}"
REL="${REL:-dotnet-base-10.0-mcr}"
TAR="${TAR:-}"
IMG="${IMG:-ems/dotnet-base:10.0-mcr}"
DL_DIR="${DL_DIR:-$PWD}"
FORCE="${FORCE:-0}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()  { printf '\033[32m[OK] %s\033[0m\n' "$*"; }
warn(){ printf '\033[33m[WARN] %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m[FAIL] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. 取包
if [ -z "$TAR" ]; then
  [ -n "$REPO" ] || die "既要本地包就设 TAR=，要在线取就设 REPO=owner/repo"
  BASE_URL="https://github.com/${REPO}/releases/download/${REL}"
  TAR="$DL_DIR/base.tar.gz"
  if [ "$FORCE" != "1" ] && [ -s "$TAR" ]; then
    say "本地已有 $TAR（$(du -h "$TAR" | cut -f1)），跳过下载；要重下加 FORCE=1"
  else
    say "从 Release 下载：${BASE_URL}/base.tar.gz"
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$TAR" "${BASE_URL}/base.tar.gz" \
      || die "下载失败：确认 Release「${REL}」下有 base.tar.gz（用 Assets 列表核对，不要猜名字）"
  fi
  [ -f "${TAR}.sha256" ] || \
    curl -fsL --retry 3 --retry-delay 2 --connect-timeout 15 -o "${TAR}.sha256" "${BASE_URL}/base.tar.gz.sha256" \
      || warn "未能取到 base.tar.gz.sha256，跳过文件级校验"
  [ -f "$DL_DIR/digest.txt" ] || \
    curl -fsL --retry 2 --connect-timeout 15 -o "$DL_DIR/digest.txt" "${BASE_URL}/digest.txt" \
      || warn "未能取到 digest.txt，将跳过层指纹比对"
fi

[ -f "$TAR" ] || die "找不到镜像包 $TAR"
TAR_DIR=$(cd "$(dirname "$TAR")" && pwd)
TAR_NAME=$(basename "$TAR")
SUMS="${TAR}.sha256"
DIGEST_FILE="$TAR_DIR/digest.txt"
say "镜像包：$TAR（$(du -h "$TAR" | cut -f1)）"

# ---------------------------------------------------------------- 2. 文件级校验
say "sha256 校验"
if [ -f "$SUMS" ]; then
  ( cd "$TAR_DIR" && sha256sum -c "$(basename "$SUMS")" ) || die "sha256 不匹配：文件损坏或被篡改，终止导入"
else
  warn "无 ${TAR_NAME}.sha256，跳过文件级校验（后续仍有层指纹比对兜底）"
fi

# ---------------------------------------------------------------- 3. 备份同名镜像
if docker image inspect "$IMG" >/dev/null 2>&1; then
  OLD_ID=$(docker image inspect --format '{{.Id}}' "$IMG")
  BAK_TAG="${IMG%%:*}:pre-import-$(date +%Y%m%d%H%M)"
  say "本地已有 $IMG（${OLD_ID:0:19}…），备份为 $BAK_TAG"
  docker tag "$IMG" "$BAK_TAG"
  echo "  回退命令：docker tag $BAK_TAG $IMG"
fi

# ---------------------------------------------------------------- 4. 导入
say "docker load"
gunzip -c "$TAR" | docker load || die "docker load 失败（包不完整或架构不符）"
docker image inspect "$IMG" >/dev/null 2>&1 || die "load 完成但未见 $IMG，检查包内 tag 是否为 ${IMG}"

# ---------------------------------------------------------------- 5. 校验
say "内容级 + 契约级校验"
[ -f "$DIGEST_FILE" ] || warn "未取得 digest.txt（$DIGEST_FILE），只能做契约级校验"
RC=0
IMG="$IMG" DIGEST="$DIGEST_FILE" bash ./verify-base.sh || RC=$?

case "$RC" in
  0) ok "基线导入完成，可用于构建业务镜像" ;;
  2) warn "基线导入完成，但有告警项（见上），不影响使用" ;;
  *) die "校验未通过，不要用这个镜像构建业务镜像；已保留备份 tag 以便回退" ;;
esac

# ---------------------------------------------------------------- 6. 收尾提示
say "当前基线镜像"
docker images | grep -E "REPOSITORY|$(echo "$IMG" | cut -d: -f1)" || true
echo
echo "业务侧契约：Dockerfile 只改 FROM 一行 -> FROM ${IMG}"
echo "  禁止在业务 Dockerfile 里出现 useradd -u 1654（会与镜像内 appuser 冲突）"
echo "回退：docker tag ${IMG%%:*}:pre-import-<时间戳> ${IMG}"
exit "$RC"
