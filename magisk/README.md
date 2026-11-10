# Gopeed 魔改版 · 系统级模块

作者：**vip-svip**

## 安装即生效

刷入 zip 后：

1. **APK 就位** —— 复制到 `/system/app/Gopeed/Gopeed.apk`，系统扫描即注册为系统应用
2. **立即安装** —— 安装阶段直接执行 `pm install -r -g -d`，装完就能用，**不需要等重启**
3. **服务自启** —— `service.sh` 开机拉起下载服务与崩溃守护
4. **命令可用** —— `gopeed` / `gopeed-cli` / `hlsdl` / `gopeed-hls` / `gopeedctl` 全局可用

安装脚本会逐项校验随包内容并打印结果，缺失会直接 abort，不会装出一个半残模块。

## 协议

全部由软件端 Go 内核处理，模块内没有独立下载核心：

| 协议 | 入口 |
|---|---|
| HTTP / HTTPS | `http://` `https://` |
| FTP / FTPS / FTPES | `ftp://` `ftps://` `ftpes://` |
| BitTorrent | `.torrent` |
| Magnet | `magnet:?xt=urn:btih:...` |
| ed2k | `ed2k://` |
| HLS | `.m3u8`（AES-128、fMP4、BYTERANGE、直播窗口） |

不含任何 DRM / 付费授权绕过能力。

## 用法

```sh
# 任意协议
gopeed "https://example.com/big.iso" -D /sdcard/Download -C 16
gopeed "magnet:?xt=urn:btih:..." -D /sdcard/Download

# 封装入口（默认存到 Download）
gopeed-hls "https://example.com/index.m3u8"

# 状态
gopeedctl status
gopeedctl protocols
```

浏览器访问 `http://127.0.0.1:9999` 使用图形界面。

## 卸载（0 残留）

移除模块并重启，`uninstall.sh` 会：

1. 停止守护与主进程，`am force-stop` 应用
2. 扫描 `/proc` 结束所有相关残留进程
3. 删软链（`/system/bin`、KSU/APatch bin）
4. 解绑 `resolv.conf`
5. 删 `/data/adb/gopeed`（配置/日志/分片/索引/BT 状态）
6. 删应用私有数据（CE / DE / `profiles`）
7. 删外部存储数据（`Android/data|media|obb`）
8. 删 `dalvik-cache`、`/data/app` 解压副本、下载目录 APK 副本
9. 清 `modules_update` 暂存目录
10. 两轮复查，被延迟重建的再删一次，最后输出是否 0 残留

你自己的下载文件不会被删除。

## 许可

Gopeed 本体：[GopeedLab/gopeed](https://github.com/GopeedLab/gopeed)，GPLv3。
本模块为打包与启动脚本集成。
