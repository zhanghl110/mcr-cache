#!/usr/bin/env bash
# =============================================================================
# verify-base.sh —— 校验已导入的基线镜像是否与构建侧一致、契约是否成立
#
# 为什么单独一个脚本：docker save/load 跨 Docker 版本往返后 image ID 会变
# （v1 实测 97cc3faa -> d7346f44），所以"ID 相等"不能作为判据，
# 内容级判据是 RootFS 层指纹；契约级判据是 uid/appuser/四个库/时区/目录属主。
#
# 用法：
#   bash verify-base.sh                                  # 校验 ems/dotnet-base:10.0-mcr
#   IMG=ems/dotnet-base:10.0.14 DIGEST=dist/digest.txt bash verify-base.sh
#
# 退出码：0 = 全部通过；1 = 有硬性项不通过（不要拿去构建业务镜像）；2 = 仅告警
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

IMG="${IMG:-ems/dotnet-base:10.0-mcr}"
DIGEST="${DIGEST:-digest.txt}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()  { printf '\033[32m[OK] %s\033[0m\n' "$*"; }
warn(){ printf '\033[33m[WARN] %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m[FAIL] %s\033[0m\n' "$*" >&2; exit 1; }

docker image inspect "$IMG" >/dev/null 2>&1 || die "本地没有 $IMG，先 load"
WARN_ONLY=0

# ---------------------------------------------------------------- 1. 内容级：层指纹
say "内容级校验：层指纹"
ACT_LAYERS=$(docker image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' "$IMG")
ACT_COUNT=$(printf '%s\n' "$ACT_LAYERS" | grep -c . || true)
echo "  实际层数: $ACT_COUNT"

if [ -f "$DIGEST" ]; then
  EXP_COUNT=$(awk -F= '/^layer_count=/{print $2}' "$DIGEST" | tr -d '[:space:]')
  EXP_LAYERS=$(awk -F= '/^layer_diff_ids=/{print $2}' "$DIGEST" | tr -d '[]"' | tr ',' '\n' | sed '/^$/d')
  [ -n "${EXP_COUNT:-}" ] && echo "  预期层数: $EXP_COUNT"
  if [ -n "${EXP_COUNT:-}" ] && [ "$ACT_COUNT" != "$EXP_COUNT" ]; then
    die "层数不符（实际 $ACT_COUNT / 预期 $EXP_COUNT）：镜像不是这份 digest.txt 对应的产物"
  fi
  if [ -n "${EXP_LAYERS:-}" ] && [ "$EXP_LAYERS" != "$ACT_LAYERS" ]; then
    echo "  ---- 预期层 ----"; printf '%s\n' "$EXP_LAYERS"
    echo "  ---- 实际层 ----"; printf '%s\n' "$ACT_LAYERS"
    die "层指纹不一致：字节内容与构建侧不同，禁止用于构建"
  fi
  ok "层指纹与 digest.txt 逐条一致（$ACT_COUNT 层）"
else
  warn "未找到 $DIGEST，跳过指纹比对（只能做契约级校验）"
  WARN_ONLY=1
fi

# ---------------------------------------------------------------- 2. 契约级：镜像默认身份
say "契约级校验：默认用户必须是 root"
UID0=$(docker run --rm "$IMG" id -u)
[ "$UID0" = "0" ] || die "默认用户 uid=${UID0}，必须为 0。基线若以 appuser 收尾，下游业务镜像所有 RUN 都会 Permission denied（v1 事故）"
ok "默认用户 uid=0（业务侧末尾 USER appuser 负责切换运行身份）"

# ---------------------------------------------------------------- 3. 契约级：运行期依赖
say "契约级校验：运行期依赖与目录"
docker run --rm "$IMG" sh -c '
  set -e
  . /etc/os-release; echo "  OS: ${PRETTY_NAME}"
  echo "  dotnet: $(dotnet --version 2>/dev/null || echo unknown)"
  dotnet --list-runtimes | grep -q "Microsoft.AspNetCore.App 10\." || { echo "  缺 ASP.NET Core 10 运行时"; exit 1; }
  for l in libfontconfig libfreetype libgssapi_krb5; do
    ldconfig -p | grep -q "$l" || { echo "  缺 $l"; exit 1; }
  done
  command -v curl >/dev/null || { echo "  缺 curl"; exit 1; }
  getent passwd 1654 | grep -q appuser || { echo "  1654 不是 appuser"; exit 1; }
  echo "  appuser: $(getent passwd 1654)"
  echo "  HOME=$HOME"
  test -d /app/DataProtection && test -d /app/logs || { echo "  缺 /app 子目录"; exit 1; }
  test "$(stat -c %u /app)" = "1654" || { echo "  /app 属主不是 1654"; exit 1; }
  echo "  /app 属主: $(stat -c %U:%G /app)"
  readlink -f /etc/localtime | grep -q Asia/Shanghai || { echo "  时区未设为 Asia/Shanghai"; exit 1; }
  echo "  时区: $(readlink -f /etc/localtime)"
  echo "  库命中数: $(ldconfig -p | grep -cE "libfontconfig|libfreetype|libgssapi_krb5")"
' || die "契约级校验失败：该镜像不能作为业务基线"

# ---------------------------------------------------------------- 4. 别名 tag
say "别名 tag 检查（按版本锁定时用）"
if [ -f "$DIGEST" ]; then
  for t in $(awk -F= '/^tags=/{print $2}' "$DIGEST" | tr ',' ' '); do
    if docker image inspect "${IMG%%:*}:${t}" >/dev/null 2>&1; then
      echo "  ✅ ${IMG%%:*}:${t}"
    else
      warn "❌ 缺少 tag ${IMG%%:*}:${t}（不影响使用，但无法按版本锁定）"
      WARN_ONLY=1
    fi
  done
fi

echo
if [ "$WARN_ONLY" = "1" ]; then
  printf '\033[33m[PASS with WARN] 硬性项全部通过，仅存在告警项\033[0m\n'
  exit 2
fi
printf '\033[32m[PASS] 基线镜像校验全部通过\033[0m\n'
