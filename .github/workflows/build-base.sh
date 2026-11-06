#!/usr/bin/env bash
# =============================================================================
# build-base.sh —— 构建 ems/dotnet-base:10.0-mcr 基线镜像并导出可分发的 tar
#
# 在哪跑：任何 linux/amd64 + 有干净公网 apt 的机器。当前主路径是 GitHub Actions
#         （内网 apt 被 NOSPLIT 劫持，本机 apt-get 装不了包）。
# 产出：dist/base.tar.gz / .sha256 / base.part-* / digest.txt
#
# 用法：
#   bash build-base.sh
#   PRIMARY_TAG=10.0-mcr SPLIT_SIZE=45m bash build-base.sh
#   REUSE=1 bash build-base.sh        # 复用已存在的本地镜像，只重做自检与导出
#
# 可覆盖变量：
#   REPO_IMG     镜像仓库名，默认 ems/dotnet-base
#   PRIMARY_TAG  主 tag，默认 10.0-mcr
#   DOCKERFILE   默认 Dockerfile
#   DIST         输出目录，默认 dist
#   PLATFORM     默认 linux/amd64
#   SPLIT_SIZE   分片大小，默认 45m；设为 0 表示不切片
#   REUSE        1 = 跳过 docker build，直接对已有镜像做自检与导出
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

REPO_IMG="${REPO_IMG:-ems/dotnet-base}"
PRIMARY_TAG="${PRIMARY_TAG:-10.0-mcr}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"
DIST="${DIST:-dist}"
PLATFORM="${PLATFORM:-linux/amd64}"
SPLIT_SIZE="${SPLIT_SIZE:-45m}"
REUSE="${REUSE:-0}"
IMG="${REPO_IMG}:${PRIMARY_TAG}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()  { printf '\033[32m[OK] %s\033[0m\n' "$*"; }
warn(){ printf '\033[33m[WARN] %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m[FAIL] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. 前置检查
say "环境检查"
command -v docker >/dev/null || die "未找到 docker"
docker info >/dev/null 2>&1 || die "docker daemon 不可用（权限或未启动）"
ARCH=$(uname -m)
[ "$ARCH" = "x86_64" ] || die "构建机架构为 ${ARCH}，本镜像按 linux/amd64 产出，请在 x86_64 上构建"
[ -f "$DOCKERFILE" ] || die "缺少 $DOCKERFILE（本脚本必须在包含 Dockerfile 的目录运行）"
ok "docker $(docker version --format '{{.Server.Version}}') / ${ARCH}"

# ---------------------------------------------------------------- 1. 静态校验
# v1 事故根因就是这里没拦住：基线一旦以非 root 收尾，下游业务镜像全部 RUN 失效
say "静态校验 $DOCKERFILE"
grep -qE '^FROM mcr\.microsoft\.com/dotnet/aspnet:' "$DOCKERFILE" \
  || die "FROM 必须指向官方 mcr.microsoft.com/dotnet/aspnet 镜像"
if grep -qE '^[[:space:]]*USER[[:space:]]' "$DOCKERFILE"; then
  grep -nE '^[[:space:]]*USER[[:space:]]' "$DOCKERFILE" >&2
  die "基线 Dockerfile 不得包含 USER 指令：会让下游业务镜像每个 RUN 以 uid 1654 执行并因权限失败（v1 事故）"
fi
grep -q 'usermod -l appuser' "$DOCKERFILE" || die "缺少 usermod 把 app 改名为 appuser 的步骤（业务侧 id -u appuser 会落空）"
grep -q 'libfontconfig1' "$DOCKERFILE" || die "缺少 libfontconfig1（验证码会 500）"
grep -q 'libfreetype6'   "$DOCKERFILE" || die "缺少 libfreetype6（验证码会 500）"
ok "静态校验通过：无 USER / FROM 官方 / 含字体链与改名步骤"

# ---------------------------------------------------------------- 2. 构建
if [ "$REUSE" = "1" ] && docker image inspect "$IMG" >/dev/null 2>&1; then
  say "REUSE=1 且 $IMG 已存在，跳过构建"
else
  say "构建 $IMG（platform=${PLATFORM}）"
  docker build --platform "$PLATFORM" -f "$DOCKERFILE" -t "$IMG" . \
    || die "构建失败：若卡在 apt-get，说明本机 apt 不可用，请改在 GitHub Actions 上构建"
fi

# ---------------------------------------------------------------- 3. 取运行时版本并打别名 tag
say "解析运行时版本并打别名 tag"
DOTNET_VER=$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$IMG" \
             | awk -F= '/^DOTNET_VERSION=/{print $2; exit}')
ASPNET_VER=$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$IMG" \
             | awk -F= '/^ASPNET_VERSION=/{print $2; exit}')
[ -n "${DOTNET_VER:-}" ] || die "未能从镜像 config 读取 DOTNET_VERSION"
DATE_TAG=$(date -u +%Y%m%d)
docker tag "$IMG" "${REPO_IMG}:${DOTNET_VER}"
docker tag "$IMG" "${REPO_IMG}:${DATE_TAG}"
ok "tags: ${PRIMARY_TAG} / ${DOTNET_VER} / ${DATE_TAG}（同一 image ID）"

# ---------------------------------------------------------------- 4. 运行期自检
say "运行期自检（任何一项不过都终止，不产出可分发文件）"
UID0=$(docker run --rm --platform "$PLATFORM" "$IMG" id -u)
[ "$UID0" = "0" ] || die "基线默认用户 uid=${UID0}，必须是 0(root)。有人给 Dockerfile 加了 USER，先删掉再构建"

docker run --rm --platform "$PLATFORM" "$IMG" sh -c '
  set -e
  head -3 /etc/os-release
  dotnet --list-runtimes | grep -q "Microsoft.AspNetCore.App 10\."
  n=$(ldconfig -p | grep -cE "libfontconfig|libfreetype|libgssapi_krb5")
  [ "$n" -ge 3 ] || { echo "库不全：$n/3"; exit 1; }
  command -v curl >/dev/null
  getent passwd 1654 | grep -q appuser
  test -d /app/DataProtection && test -d /app/logs
  test "$(stat -c %u /app)" = "1654"
  [ -e /etc/localtime ] && readlink -f /etc/localtime | grep -q Asia/Shanghai
  echo "自检通过"
' || die "运行期自检失败（详见上方输出）"
ok "运行期自检全绿（root 收尾 / appuser 1654 / 4 个补齐包 / 时区 / /app 目录）"

# ---------------------------------------------------------------- 5. 生成校验基准
say "生成 digest.txt"
mkdir -p "$DIST"
LAYERS_JSON=$(docker image inspect --format '{{json .RootFS.Layers}}' "$IMG")
LAYER_COUNT=$(printf '%s' "$LAYERS_JSON" | grep -o 'sha256:' | wc -l | tr -d ' ' || true)
[ "${LAYER_COUNT:-0}" -ge 8 ] || die "层数异常（${LAYER_COUNT}），预期 8 层（官方 6 + 补齐 2）"
{
  echo "image=${REPO_IMG}"
  echo "tags=${PRIMARY_TAG},${DOTNET_VER},${DATE_TAG}"
  echo "primary_tag=${PRIMARY_TAG}"
  echo "base=$(awk '/^FROM /{print $2; exit}' "$DOCKERFILE")"
  echo "dotnet_version=${DOTNET_VER}"
  echo "aspnet_version=${ASPNET_VER:-unknown}"
  echo "dockerfile_sha256=$(sha256sum "$DOCKERFILE" | cut -d' ' -f1)"
  echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "builder=$(uname -n)/docker-$(docker version --format '{{.Server.Version}}')"
  echo "image_id=$(docker image inspect --format '{{.Id}}' "$IMG")"
  echo "layer_count=${LAYER_COUNT}"
  echo "layer_diff_ids=${LAYERS_JSON}"
  echo "default_uid=${UID0}"
  echo "size_bytes=$(docker image inspect --format '{{.Size}}' "$IMG")"
} | tee "$DIST/digest.txt"
ok "layer_count=${LAYER_COUNT}（官方 6 层 + 补齐层 2 层，正常应为 8）"

# ---------------------------------------------------------------- 6. 导出
say "docker save（三个 tag 打进同一个 tar，内网 load 后可直接按版本锁定）"
docker save "${IMG}" "${REPO_IMG}:${DOTNET_VER}" "${REPO_IMG}:${DATE_TAG}" \
  | gzip -1 > "$DIST/base.tar.gz"
tar -tzf "$DIST/base.tar.gz" | grep -qx 'manifest.json' \
  || die "导出的 tar 缺少 manifest.json（可能被 BuildKit attestation 改写），不要发布这个包"

( cd "$DIST" && sha256sum base.tar.gz > base.tar.gz.sha256 )
ls -lh "$DIST/base.tar.gz"

if [ "$SPLIT_SIZE" != "0" ]; then
  say "切分片（${SPLIT_SIZE}，用于 Release 单文件上限与断点重传）"
  rm -f "$DIST"/base.part-*
  split -b "$SPLIT_SIZE" -d -a 2 "$DIST/base.tar.gz" "$DIST/base.part-"
  ( cd "$DIST" && sha256sum base.part-* > base.parts.sha256 )
  ls -lh "$DIST"/base.part-*
fi

# ---------------------------------------------------------------- 7. 收尾
say "完成"
cat "$DIST/base.tar.gz.sha256"
echo
echo "镜像：${IMG}（= ${REPO_IMG}:${DOTNET_VER} = ${REPO_IMG}:${DATE_TAG}）"
echo "产物：${DIST}/base.tar.gz  $(du -h "$DIST/base.tar.gz" | cut -f1)"
echo
echo "下一步：bash publish-release.sh   # 发布到 GitHub Release"
echo "内网侧：REPO=<owner/repo> bash load-base.sh"
