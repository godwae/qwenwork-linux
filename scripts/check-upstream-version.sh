#!/bin/bash
set -euo pipefail

# 查询 QwenWorkCN（千问办公）官方最新版本，与本地已安装版本对比。
#
# 背景：Linux 移植版屏蔽了应用内"检查更新"（避免无 Updater 二进制的下载流程），
# 官网下载页也不显示版本号。本脚本复刻应用内部的升级查询请求
# （POST https://clientupgrade.qwenwork.cn/upgrade/query，仅需合成 UUID，无需登录），
# 用于随时确认官方是否发布了新版本。
#
# 用法：
#   bash scripts/check-upstream-version.sh            # 自动读取本地版本
#   bash scripts/check-upstream-version.sh 0.1.7      # 手动指定本地版本
#   make check-update                                 # 等价于第一种
#
# 退出码：
#   0 = 已是最新版本
#   1 = 官方有新版本（见 stdout 提示）
#   2 = 查询失败（网络/解析错误）

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

UPGRADE_ENDPOINT="${QODERWORK_UPGRADE_ENDPOINT:-https://clientupgrade.qwenwork.cn/upgrade/query}"
UPGRADE_APP_NAME="qwenworkcn"
UPGRADE_CHANNEL="stable"

info() { echo "[check-update] $*"; }
error() { echo "[check-update] 错误: $*" >&2; }

read_local_version() {
    local f="${1:-}"
    if [ -z "$f" ] || [ ! -f "$f" ]; then
        return 1
    fi
    python3 - "$f" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        print(json.load(fh).get("upstreamVersion", ""))
except Exception:
    pass
PY
}

resolve_local_version() {
    local v="${1:-}"
    if [ -n "$v" ]; then
        echo "$v"
        return 0
    fi
    # 依次尝试本地构建与 /opt 安装版的 build-info.json
    v="$(read_local_version "$REPO_DIR/qwenwork-app/.qwenwork-linux/build-info.json")"
    [ -n "$v" ] || v="$(read_local_version "/opt/qwenwork-cn/.qwenwork-linux/build-info.json")"
    [ -n "$v" ] || v="$(read_local_version "$REPO_DIR/dist/rpm-root/opt/qwenwork-cn/.qwenwork-linux/build-info.json")"
    if [ -z "$v" ]; then
        error "无法确定本地版本。请手动指定：bash $0 <版本号>"
        exit 2
    fi
    echo "$v"
}

query_upgrade() {
    local version="$1"
    local uuid
    uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-0000-0000-000000000000")"

    curl -sS --max-time 20 -X POST "$UPGRADE_ENDPOINT" \
        -H "Content-Type: application/json" \
        -d "{
  \"appInfo\": {\"name\":\"$UPGRADE_APP_NAME\",\"version\":\"$version\",\"arch\":10,\"channel\":\"$UPGRADE_CHANNEL\",\"language\":\"zh_CN\",\"lastVersion\":[],\"env\":0,\"skipVersion\":\"\",\"manual\":true,\"installType\":\"system\",\"archType\":1,\"updaterVersion\":\"0.0.3\",\"upgradePendingVersion\":\"\",\"keyModules\":[]},
  \"osInfo\": {\"type\":0,\"arch\":1,\"version\":\"\",\"platform\":\"linux\"},
  \"hardwareInfo\": {\"machineId\":\"$uuid\"},
  \"userInfo\": {\"uuid\":\"$uuid\",\"uid\":\"\",\"orgIds\":[],\"token\":\"\",\"userTag\":[]},
  \"ext\": {}, \"reqId\": 0, \"checkType\": 0
}"
}

main() {
    local local_version latest_version action resp
    local_version="$(resolve_local_version "${1:-}")"
    info "本地版本: $local_version"

    resp="$(query_upgrade "$local_version")" || {
        error "查询失败（网络或端点不可达）"
        exit 2
    }

    action="$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("upgradeAction", -1))
except Exception:
    print(-1)
' 2>/dev/null || echo -1)"
    latest_version="$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    u = d.get("upgradeInfo") or {}
    print(u.get("version", ""))
except Exception:
    pass
' 2>/dev/null || true)"

    if [ "$action" = "1" ] && [ -n "$latest_version" ]; then
        info "官方已发布新版本: $latest_version"
        info "升级路径: 前往官方渠道下载新版 Intel/x64 DMG，放入 downloads/ 后执行:"
        info "  make build-app && make package"
        exit 1
    fi

    info "已是最新版本（官方最新: ${latest_version:-$local_version}）"
    exit 0
}

main "$@"
