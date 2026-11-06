# =============================================================================
# Dockerfile —— ems/dotnet-base:10.0-mcr（官方 aspnet 10.0 + 补齐层基线）
#
# 【唯一权威定义】本文件由 build-base.yml 通过 actions/checkout 取用，
#   即 Actions 里构建的就是这一份。不要在 workflow 里内联 Dockerfile，
#   两份定义必然漂移（v1 就是这样翻车的：yml 内联版多了一条 `USER appuser`，
#   导致业务镜像所有 RUN 以 uid 1654 执行，构建在 `ln -snf /etc/localtime` 处
#   Permission denied）。
#
# 定位：官方 `mcr.microsoft.com/dotnet/aspnet:10.0`（Ubuntu 24.04 noble）
#   不含验证码所需的 libfontconfig1 / libfreetype6 / libgssapi-krb5-2 / curl，
#   而内网 apt 被劫持（Clearsigned file isn't valid, got 'NOSPLIT'），现场装不了。
#   所以在有干净公网 apt 的 runner 上构建好，整镜像导出，内网只 load。
#
# 与自建基线 aspnetcore:10-debian 的契约（必须逐条保持）：
#   1. uid/gid 1654，用户名 appuser（业务 Dockerfile 靠 id -u appuser 跳过 useradd）
#   2. HOME=/app，/app/DataProtection 与 /app/logs 预建且属主 1654
#   3. 【铁律】本文件必须以 root 结束，不写 USER
#      运行身份由业务 Dockerfile 末尾的 USER appuser 决定
#   4. 自带 fontconfig / freetype / gssapi-krb5 / curl
#
# 手工复现（任何有干净 apt 的 linux/amd64 机器）：
#   bash build-base.sh
# =============================================================================
FROM mcr.microsoft.com/dotnet/aspnet:10.0

ARG APP_UID=1654
ARG APP_GID=1654

ENV TZ=Asia/Shanghai \
    HOME=/app \
    DOTNET_RUNNING_IN_CONTAINER=true

# 官方 runtime-deps 已装：ca-certificates / libicu / libssl3t64 / libstdc++6 / tzdata
# 这里只补缺的：字体链（SkiaSharp 画验证码）、Kerberos、curl（HTTP 探活用）
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libfontconfig1 \
        libfreetype6 \
        libgssapi-krb5-2 \
        curl; \
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime; \
    echo "${TZ}" > /etc/timezone; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /app/DataProtection /app/logs; \
    usermod -l appuser -d /app -s /usr/sbin/nologin app; \
    chown -R "${APP_UID}:${APP_GID}" /app

# 构建期自检：把问题暴露在 CI，不要留到生产
RUN set -eux; \
    command -v dotnet; \
    dotnet --list-runtimes | grep -q 'Microsoft.AspNetCore.App 10\.'; \
    ldconfig -p | grep -q libfontconfig; \
    ldconfig -p | grep -q libfreetype; \
    ldconfig -p | grep -q libgssapi_krb5; \
    command -v curl; \
    test -e /usr/share/zoneinfo/Asia/Shanghai; \
    id appuser; \
    getent passwd 1654 | grep -q appuser

LABEL org.opencontainers.image.title="ems-dotnet-base" \
      org.opencontainers.image.base.name="mcr.microsoft.com/dotnet/aspnet:10.0" \
      org.opencontainers.image.description="官方 aspnet 10.0 + 字体/Kerberos/curl 补齐层（uid 1654，root 收尾）" \
      org.opencontainers.image.vendor="Alon" \
      maintainer="Alon"

# 保持 root 收尾（见文件头铁律第 3 条），不要在这里加 USER。
