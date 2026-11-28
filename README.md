# 状态栏扩展

适用于 Apple 芯片 Mac（macOS 26 或更高版本）的菜单栏工具。实时显示上传和下载网速，悬停可查看 HTTPS 和 TCP 探测的耗时及近 5 分钟成功率。菜单还提供秒表、环境音监听、系统状态、音量键微调、睡眠控制、文本行数统计和 Mac 附加文件清理。

将仓库根目录的 `状态栏扩展.app` 复制到「应用程序」即可使用。

## 配置

配置保存在 `~/Library/Application Support/NetRate/`。站点、秒表、环境音、系统状态和音量键分别对应 `config.json`、`stopwatch.json`、`hearing.json`、`system-status.json` 和 `volume-keys.json`。

HTTPS 站点可直接填写 `example.com/health`，TCP 站点分别填写主机和端口。手动修改站点配置后，在探测站点配置窗口选择「配置文件 → 重新读取配置」。

悬停状态栏入口预览，左键打开面板，右键打开总菜单。点击图钉或拖动背景可固定面板，再点图钉收起。勾选「系统状态」可显示电池入口，查看 CPU、内存、启动盘和温度。

鼠标移入网速浮窗可查看每种探测方式的在途请求和下次发起时间。点击「立即探测」可刷新已启用的方式。

## 构建与测试

安装 Xcode 后，在项目目录运行以下命令。

```sh
./scripts/build.sh       # 构建并更新根目录的签名 App
./scripts/test.sh        # 日常快速测试
./scripts/test.sh full   # 完整回归测试
```
