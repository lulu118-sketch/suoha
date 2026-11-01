# Suoha

**Suoha** 是一个面向 Debian、Ubuntu 和 Alpine 的 Bash 安装/管理脚本，使用 Xray 提供 VLESS + Trojan over WebSocket，并通过 Cloudflare Tunnel 对外提供连接入口和订阅。主程序来源于[GitHub仓库](https://github.com/jwfst5088/suoha.sh)，后来再进行加工！

> 本项目仍建议先在测试 VPS 上验证，再用于正式环境。Cloudflare Tunnel、Xray、系统服务和订阅配置均会在 VPS 上创建或修改。

## 功能

- Quick Tunnel：使用 Cloudflare 临时域名，提供 VLESS、Trojan 和订阅入口。
- 固定域名 Tunnel：通过 Cloudflare 浏览器授权，创建/复用 Tunnel，并自动创建 DNS 路由。
- 输出通用订阅和 Clash/Mihomo YAML 订阅。
- 提供交互式管理菜单：查看链接、查看状态、重启、停止、启动和卸载。
- 支持 Debian / Ubuntu（systemd）及 Alpine（OpenRC）。
- 支持 x86_64、ARM64、ARMv7、i386 等脚本中列出的架构。

## 系统要求

- Root 权限。
- Debian / Ubuntu（systemd）或 Alpine（OpenRC）。
- 可访问 GitHub、Cloudflare。
- 固定域名模式需要域名已添加到当前 Cloudflare 账号托管的 Zone。
- 运行时会下载 Xray 和 cloudflared 的最新发行版。

## 安装


```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lulu118-sketch/suoha/main/suoha.sh)
```

也可以先下载，再运行：

```bash
curl -fL https://raw.githubusercontent.com/lulu118-sketch/suoha/main/suoha.sh -o suoha.sh && chmod 700 suoha.sh && bash suoha.sh
```

## 安装模式

1. **Quick Tunnel**：不需要自有域名，但 Cloudflare 分配的是临时域名；域名可能在隧道重建后变化。
2. **固定域名 Tunnel**：需要在 Cloudflare 完成浏览器授权，并输入已托管在该账号下的完整域名。

## 安装后的管理

安装完成后可运行：

```bash
suoha
```

按菜单操作。脚本会在 `/opt/suoha` 保存程序配置、状态、日志和生成的订阅数据。

## 安全提示

- `links.txt` 中包含节点连接信息和带随机令牌的订阅 URL，**不要公开发布、提交到 GitHub 或发给不可信的人**。
- Cloudflare 授权凭据保存在 VPS 的 `/root/.cloudflared/`，不要上传到仓库。
- VPS 上的运行状态、私钥、凭据、节点文件和订阅文件均不应提交到 Git。
- 公开仓库只应包含安装脚本、文档和必要的项目文件。
- 订阅 URL 中的随机令牌相当于访问凭据；泄露后应重新生成并更新配置。
- 脚本会以 root 身份安装软件包、下载并运行二进制文件、创建系统服务和修改 Cloudflare Tunnel/DNS。请先审阅代码并确认信任来源。

## 当前版本

- Script version: `2.0.0`

## 反馈与问题

请在 GitHub 仓库的 **Issues** 页面提交问题，并附上已脱敏的系统信息和错误日志。不要提交 UUID、订阅链接、Cloudflare 凭据、域名账户令牌或私钥。
