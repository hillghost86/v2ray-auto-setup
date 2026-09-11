# v2ray.sh

一个脚本在 Debian / Ubuntu 服务器上装好 **V2Fly v5 + Caddy 2**，用 **VMess + WebSocket + TLS** 组合，证书自动申请、自动续期。装完直接给出客户端链接和二维码。

全部跑在 Docker 里，不往系统里装 V2Ray 或 Nginx，卸载干净。

## 需要准备

- 一台 Debian / Ubuntu 服务器（需要 systemd，root 权限）
- 一个域名，A 记录指向服务器公网 IP
- 服务器防火墙放行 **TCP 80 和 443**（80 用来申请证书，不能省）

Docker、Docker Compose、qrencode 这些依赖脚本会自己装。

## 使用

所有子命令都要 root（配置在 `/root/v2ray-stack` 下，还要动 Docker、apt、systemd 和 80/443 端口）。先 `sudo -i` 切到 root，然后：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hillghost86/v2ray-auto-setup/main/v2ray.sh)
```

不想切 root 就用管道加 `sudo`：

```bash
curl -fsSL https://raw.githubusercontent.com/hillghost86/v2ray-auto-setup/main/v2ray.sh | sudo bash -s -- install
```

> 唯独 `sudo bash <(curl ...)` **不能用**。进程替换的 `/dev/fd/63` 是调用者进程的管道，而 sudo 默认 `closefrom=3` 会关掉 3 号以上所有文件描述符，新进程再去打开它只会得到 `No such file or directory`。要么用上面的管道写法，要么下载到本地再 `sudo bash v2ray.sh`。

不带参数会进菜单：

```
 1) 安装 / 修改配置
 2) 更新到最新版
 3) 查看运行状态
 4) 显示客户端链接和二维码
 5) 只显示链接（不显示二维码）
 6) 卸载
 0) 退出
```

也可以直接指定子命令（把 `install` 换成下表里任意一个）：

| 子命令 | 作用 |
| --- | --- |
| `install` | 安装，或修改域名 / UUID / 路径后重新应用 |
| `update` | 拉最新镜像重建容器，自检不过可一键回退旧版本 |
| `status` | 容器状态、版本、证书有效期、链路自检 |
| `show` | 打印客户端配置、vmess 链接和二维码（`show plain` 不画二维码） |
| `uninstall` | 删除容器，可选一并删除证书和配置目录 |

安装时需要填 4 项，回车即用默认值：

- **域名** — 已解析到本机的那个
- **UUID** — 回车随机生成
- **WebSocket 路径** — 回车随机生成，例如 `/a1b2c3`
- **是否走 Cloudflare CDN** — 决定域名检查时的排查提示

## 装完之后

脚本会直接输出可粘贴的 `vmess://` 链接（v2rayN、Shadowrocket 等通用），以及扫码用的二维码。二维码的宽度取决于链接长度，脚本会按实际尺寸和终端宽度挑纠错等级（优先 M，装不下退 L），实在放不下就跳过并告诉你还差几列。手动填的话：

| 项 | 值 |
| --- | --- |
| 地址 / Host / SNI | 你的域名 |
| 端口 | 443 |
| UUID | 安装时生成的那个 |
| Alter Id | 0 |
| 加密 | auto |
| 传输 | websocket |
| 路径 | 安装时生成的那个 |
| TLS | 开启 |

忘了就跑一次脚本选「显示客户端链接」。

### 用 Cloudflare CDN 的话

安装时把 CDN 选 `yes`，并在 Cloudflare 侧：

- 域名必须是**一级子域**，例如 `aws.example.com`。见下方说明
- 云朵改成**橙色**（已代理）
- SSL/TLS 模式选**完全（严格）**
- 网络里 **WebSockets 保持开启**
- **不要**开启「始终使用 HTTPS」（会挡住证书申请）

> **多级子域用不了。** Cloudflare 免费版 Universal SSL 只签 `example.com` 和 `*.example.com`，通配符不覆盖 `aws.no2.example.com` 这种多级子域。橙色云朵下客户端连的是 Cloudflare 边缘，边缘拿不出证书，直接回一个握手失败。
>
> 迷惑之处在于**源站一切正常**：Let's Encrypt 不限子域层级，证书照发，服务器上怎么测都是绿的，偏偏客户端连不上。判断方法：
>
> ```bash
> echo | openssl s_client -connect 你的域名:443 -servername 你的域名 2>&1 | head -5
> ```
>
> 出现 `no peer certificate available` 就是这个问题。解决办法：换一级子域（推荐）、把云朵改灰（同时把脚本的 CDN 选项改成 `no`），或购买 Advanced Certificate Manager 开启 Total TLS。

## 脚本做了哪些检查

这是它跟大多数一键脚本不一样的地方——不是启动完就宣布成功。

1. **装之前查域名**：临时在 80 端口起一个网页服务，再从外网经域名访问它。一次性验证 DNS 解析、云厂商防火墙、CDN 转发三件事，比 `ping` 靠谱。顺带检查 AAAA 记录是否指向别处。
2. **装之后查握手**：模拟一次 WebSocket 升级请求，返回 101 才算 Caddy → V2Ray 链路通、证书有效。
3. **最后查真连通**：起一个临时 V2Ray 客户端容器，用刚生成的 UUID 真的走一遍代理去访问外网。这一步过了，说明 UUID、路径、TLS 全都对，而不只是端口开着。
4. **CDN 模式下还要查边缘**：上面几项为了排除干扰都绕开了 Cloudflare，所以照不出边缘的毛病。开了 CDN 时会按域名真实解析再走一遍，也就是客户端实际走的那条路。

任何一步没过都会打印对应容器的日志和排查方向。`update` 也走同一套自检，新版本不过就问你要不要回退——回退用的是更新前那个镜像，所以确认没问题之前旧镜像不会被删。

## 文件位置

```
/root/v2ray-stack/.env           域名、UUID、路径、镜像版本（权限 600）
/root/v2ray-stack/compose.yaml   容器定义，V2Ray 和 Caddy 的配置内嵌其中
docker volume caddy_data         HTTPS 证书
docker volume caddy_config       Caddy 运行时配置
```

想改配置不用手动编辑这些文件，重跑脚本选「安装 / 修改配置」即可，原值会作为默认值带出来。

## 常见问题

**证书申请不下来** — 九成是 80 端口没通。检查云厂商防火墙（Lightsail 之类的安全组和系统 ufw 是两回事，脚本只会帮你开 ufw）、A 记录是否生效、Cloudflare 是否开了「始终使用 HTTPS」。

**80 端口被占用导致检查中止** — 先查是谁占着：

```bash
ss -tlnp | grep ':80 '
```

**服务起来了但连不上** — 跑一次「查看运行状态」，三项自检会分别指出是证书/握手、UUID/路径，还是 Cloudflare 边缘的问题。特别注意「源站全绿但客户端连不上」这种情况，多半是上面说的多级子域。

**提示需要 root** — 所有子命令都要 root，包括只读的 `status` 和 `show`（配置在 `/root/v2ray-stack` 下，`.env` 是 600）。用法见上面「使用」一节。

**在 Windows 上编辑过脚本** — 脚本开头自带 CRLF 自愈，是磁盘上的普通文件时会去掉 `\r` 再重新执行自己，不用手动 `dos2unix`。通过管道运行时不做这个检查（那种情况下也不会有 CRLF），否则读取自身会把数据从管道里抢走、导致脚本被截断。

**看日志**：

```bash
docker logs --tail 50 caddy
```

```bash
docker logs --tail 50 v2ray
```

## 说明

仅供在你自己拥有或获得授权的服务器上搭建个人代理使用，请遵守所在地法律法规。
