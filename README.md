# Xray 工具箱（VLESS + REALITY + SOCKS5 + 端口转发）

Debian / Ubuntu 上的 Xray 部署与管理脚本，全部功能收在一个交互菜单里。

## 功能

- **安装 / 重装**：官方 Xray-core + VLESS + REALITY（Vision 流控），随机端口，自动生成 UUID 与 x25519 密钥对
- **可选 SOCKS5**：随机端口 + 随机账号密码（强制认证，不做无认证开放代理），可开 UDP
- **查看链接**：从当前 `config.json` 实时重建，换 IP、改配置之后依然准确
- **追加 SOCKS5**：只往现有配置里追加入站，不动 REALITY（写盘前做 diff 校验，任何已有入站变化就中止）
- **端口转发**：同机用 `REDIRECT`，跨机用 `DNAT + MASQUERADE`，自动开 `ip_forward`、放行 `FORWARD` 链、规则持久化

## 环境要求

- Debian 12 / Ubuntu 22.04 及以上
- root 权限
- 能访问 GitHub（安装时需下载官方 `install-release.sh`）

## 快速开始

```bash
git clone https://github.com/<你的用户名>/xray-toolkit.git /root/xray-toolkit
bash /root/xray-toolkit/install-xray-reality.sh
```

建一次快捷命令，之后用 `xr` 即可：

```bash
bash /root/xray-toolkit/install-xray-reality.sh shortcuts
```

## 菜单

```
1) 安装 / 重新安装（REALITY，可选 SOCKS5）
2) 查看已有链接
3) 追加 SOCKS5（不动现有 REALITY）
4) 端口转发管理
5) 查看服务状态与日志
6) 退出
```

## 安全提醒

- 脚本本身**不含任何密钥**，UUID / REALITY 私钥都是安装时随机生成
- **不要把服务器上的 `/root/xray-links.txt`、`/usr/local/etc/xray/config.json` 提交到仓库**（已写入 `.gitignore`）
- SOCKS5 是明文协议，只建议自己使用
- 云服务商**安全组需要手动放行端口**，脚本不会也不能替你改

## 目录结构

```
install-xray-reality.sh   整合版，菜单入口
xray-menu.sh              同一份内容的别名
legacy/                   早期独立脚本（已被整合版取代，仅留作参考）
```
