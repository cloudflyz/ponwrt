# PVE 受限授权：只给单台 VM 电源 + 控制台

目标：管家（OpenClaw）能对**指定的** PVE 虚拟机执行开机/关机/停止/重启/查状态/看控制台，
但不持有宿主机 root，也碰不到其他 VM、存储、备份。

---

## 一、你在 PVE 网页上的操作（约 3 分钟）

以 PVE 8/9 为例，节点名假设为 `pve`，目标 VM ID 假设为 `300`。

### 步骤 1：建一个最小权限角色

`Datacenter → Permissions → Roles → Create`

- Name：`VmPowerOnly`
- Privileges 只勾这三项：
  - `VM.Audit`
  - `VM.PowerMgmt`
  - `VM.Console`

❌ 不要勾：`VM.Config.*`、`VM.Monitor`、`VM.Allocate`、`VM.Backup`、`Datastore.*`、`Sys.*`、`Permissions.*`

### 步骤 2：建 API 专用用户

`Datacenter → Permissions → Users → Add`

- User name：`openclaw`
- Realm：`PVE`
- 密码留空 / 随便设（只用 token 认证，不走密码登录）
- 不需要给这个用户任何 Group 或额外权限

### 步骤 3：给该用户签发 API Token

`Datacenter → Permissions → API Tokens → Add`

- User：`openclaw@pve`
- Token ID：`vmctl`
- **Privilege Separation：取消勾选**
  （取消后 token 继承用户权限；勾着则要单独再给 token 授权，多一步且容易漏）
- 创建后弹窗里的 `UUID` **只显示一次**，立刻复制

最终 token 串形如：

```
openclaw@pve!vmctl=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

### 步骤 4：把角色绑到「只有这一台 VM」的路径

`Datacenter → Permissions → Add → API Token`

- Path：`/vms/300`（只授权这一台；多台就逐个加，或先建 pool 再授权 `/pool/build`）
- API Token：选 `openclaw@pve!vmctl`
- Role：`VmPowerOnly`
- Propagate：勾上

### 步骤 5：把 token 交给管家（不要贴聊天）

用 OpenClaw 的掩码录入通道存成 `PVE_TOKEN`，另外告诉我这三项（都不敏感）：

- PVE 地址（如 `192.168.5.10`）
- 节点名（如 `pve`）
- 目标 VM ID（如 `300`）

---

## 二、验证（你来或我来都行）

```bash
curl -sk -H "Authorization: PVEAPIToken=openclaw@pve!vmctl=<UUID>" \
  https://192.168.5.10:8006/api2/json/nodes/pve/qemu/300/status/current
```

期望：返回 JSON，`"data": {"status": "running", ...}`。

再测开关：

```bash
# 停止
curl -sk -X POST -H "Authorization: PVEAPIToken=<token>" \
  https://192.168.5.10:8006/api2/json/nodes/pve/qemu/300/status/stop
# 启动
curl -sk -X POST -H "Authorization: PVEAPIToken=<token>" \
  https://192.168.5.10:8006/api2/json/nodes/pve/qemu/300/status/start
```

**越权验证**（应该返回 403，正是我们要的效果）：

```bash
curl -sk -H "Authorization: PVEAPIToken=<token>" \
  https://192.168.5.10:8006/api2/json/nodes/pve/qemu/999/status/current   # 别的 VM
curl -sk -H "Authorization: PVEAPIToken=<token>" \
  https://192.168.5.10:8006/api2/json/nodes/pve/qemu/300/config           # 读配置
```

---

## 三、管家侧怎么用

脚本：`scripts/pve-vmctl.sh`（在 fork 仓库里，读了环境变量才动）

```bash
export PVE_HOST=192.168.5.10
export PVE_NODE=pve
export PVE_VMID=300
# PVE_TOKEN 由 secrets 注入，不落盘

./scripts/pve-vmctl.sh status
./scripts/pve-vmctl.sh start
./scripts/pve-vmctl.sh shutdown
./scripts/pve-vmctl.sh vnc-ticket   # 拿控制台票据（配合 VNC 客户端/截图）
```

注意：`shutdown` 是 ACPI 优雅关机，`stop` 是断电式强停。日常用 `shutdown`。

---

## 四、权限边界

允许：
- 开机、关机（ACPI）、强制停止、重启 VM 300
- 查询状态
- 打开控制台（截图 / 键盘）

禁止：
- 改 VM 配置、加删硬盘、改启动顺序
- 其他 VM 的任何操作
- 宿主机 shell、`pct`、存储池、备份、删除、克隆

---

## 五、安全建议

1. **token 可随时撤销**：`API Tokens` 里删除即失效，我这边立刻报 401。
2. **不要开启 Privilege Separation 后再忘了给 token 单独授权** —— 这是 403 最常见的原因。
3. 如果 PVE 用的是自签证书，`curl -k` 会跳过校验；想更严可以把 CA 指纹固定下来。
4. 进一步收权技巧：编译结束让 VM 自己 `poweroff`，宿主机侧只需要「开机」动作，
   那就可以把角色缩减到 `VM.PowerMgmt + VM.Audit`。

---

## 六、排错对照

| 现象 | 原因 |
| --- | --- |
| 401 Unauthorized | token 串拼错（用户名/TokenID/UUID 任一不对）或 token 已删除 |
| 403 Permission check failed | 权限没绑到 `/vms/300`，或 Propagate 没勾，或勾了 Privilege Separation 但没给 token 授权 |
| 595 / 连接失败 | 地址、端口 8006、防火墙，或节点名拼错 |
| 能查状态但开不了机 | 角色漏了 `VM.PowerMgmt` |
| 能开机但控制台 403 | 角色漏了 `VM.Console` |
