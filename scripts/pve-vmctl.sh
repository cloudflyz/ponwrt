#!/bin/bash
# pve-vmctl.sh — 用受限 API Token 管理指定 VM（不需要宿主机 root）
#
# 需要环境变量（由 OpenClaw secrets 注入，不要写进文件）：
#   PVE_HOST   PVE 地址，例如 192.168.5.10 或 pve.lan
#   PVE_TOKEN  API Token 串，格式 openclaw@pve!vmctl=<UUID>
#   PVE_NODE   节点名（默认取 hostname 的第一段；可用 pvesh get /nodes 查）
#   PVE_VMID   目标 VM ID（默认 300）
#
# 用法: ./pve-vmctl.sh status|start|stop|shutdown|reboot|vnc-ticket|nodes
set -euo pipefail

HOST="${PVE_HOST:?需要 PVE_HOST}"
TOKEN="${PVE_TOKEN:?需要 PVE_TOKEN（openclaw@pve!vmctl=<UUID>）}"
NODE="${PVE_NODE:-}"
VMID="${PVE_VMID:-300}"
BASE="https://${HOST}:8006/api2/json"

api() { # method path
  curl -sk -X "$1" -H "Authorization: PVEAPIToken=${TOKEN}" "${BASE}$2"
}

resolve_node() {
  if [[ -z "$NODE" ]]; then
    NODE=$(api GET /nodes | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d[0]["node"])' 2>/dev/null || true)
  fi
  [[ -n "$NODE" ]] || { echo "无法确定节点名，请设置 PVE_NODE" >&2; exit 1; }
}

case "${1:-status}" in
  nodes)
    api GET /nodes | python3 -m json.tool
    ;;
  status)
    resolve_node
    api GET "/nodes/${NODE}/qemu/${VMID}/status/current" | python3 -m json.tool
    ;;
  start|stop|shutdown|reboot)
    resolve_node
    echo "==> ${1} VM ${VMID} @ ${NODE}"
    api POST "/nodes/${NODE}/qemu/${VMID}/status/${1}" | python3 -m json.tool || {
      echo "!! 失败：403=权限未下发到该 VM 路径；401=token 串写错；000=地址/端口/TLS 问题" >&2
      exit 1
    }
    sleep 3
    api GET "/nodes/${NODE}/qemu/${VMID}/status/current" \
      | python3 -c 'import json,sys; print("现在状态:", json.load(sys.stdin)["data"]["status"])'
    ;;
  vnc-ticket)
    resolve_node
    api POST "/nodes/${NODE}/qemu/${VMID}/vncproxy" | python3 -m json.tool
    ;;
  *)
    echo "用法: $0 {status|start|stop|shutdown|reboot|vnc-ticket|nodes}" >&2
    exit 2
    ;;
esac
