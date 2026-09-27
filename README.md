# EC20 Companion：让 Mac 使用 EC20 的短信与电话

一款面向 **Apple Silicon Mac + 移远 EC20-CE-HDLG** 的中文菜单栏应用。通过 USB Type-C 连接 EC20 后，可在 Mac 上查看 SIM 与信号、按对话管理短信、管理联系人与通话记录，并使用拨号和来电界面。项目还包含一个实验性的 iPhone 局域网配套客户端源码。

> 这是个人项目的源码，尚未发布经过公证的安装包。部分功能只有模拟测试或有限的硬件验证；使用前请先阅读[已知限制](#已知限制)。

## 功能与验证状态

| 功能 | 当前状态 |
| --- | --- |
| 识别 EC20、读取 SIM 状态、运营商及信号 | 已在 `2c7c:0125` 设备上验证基础 AT 通信 |
| 中文菜单栏、未读数、短信通知、来电浮窗 | 已实现；系统通知需授予权限 |
| 短信对话、回复、联系人备注、号码归属地、批量删除 | 已实现；编解码和删除流程有离线模拟测试，实际发送需自行验证 |
| 本地 SQLite 短信、联系人、通话记录 | 已实现；数据保存在本机用户目录 |
| 拨号、接听、挂断、USB PCM 语音桥接 | 信令和音频代码已实现；运营商通话及双向语音尚未完成端到端验证 |
| iPhone 局域网配套客户端 | 提供源码与 XcodeGen 配置；尚未在 iPhone 真机完成构建和验收 |
| 蜂窝网络开关 | 实验性；界面状态曾出现自动恢复，建议暂不使用 |

## 硬件与环境

- Apple Silicon Mac，macOS **26 或更新版本**。Swift Package 的最低版本声明为 macOS 13，但当前打包脚本所用的 Homebrew `libusb` 二进制要求 macOS 26。
- 移远 Quectel **EC20-CE-HDLG**，USB VID `0x2c7c`、PID `0x0125`，经 Type-C 连接。其他 EC20 型号和 USB 拓扑未验证。
- Xcode Command Line Tools 或 Xcode，以及 Homebrew `libusb`：

  ```bash
  xcode-select --install
  brew install libusb
  ```

应用通过 `libusb` 直接访问模块的 USB Interface 2（AT/URC，OUT `0x03`、IN `0x84`）；不依赖 `/dev/cu.*` 串口设备。macOS 上的 ECM 网络接口由系统管理。

## 构建与运行

```bash
git clone https://github.com/zshao56/EC20_sim.git
cd EC20_sim
./scripts/build_app.sh
open ./EC20Companion.app
```

`build_app.sh` 会在当前仓库生成应用包，并把 Homebrew 的 `libusb` 动态库复制进包内。若本机 Command Line Tools 存在 `MacOSX26.5.sdk`，脚本会优先使用它。也可以运行 `./scripts/build_app.sh --install` 安装到 `/Applications`；该选项会覆盖同名旧版应用，请先备份需要保留的版本。

**只跑离线测试**（不会访问 EC20、发送短信或拨号）：

```bash
swift run ec20-tests
```

`./scripts/run_probe.sh` 会连接真实模块进行只读诊断，需确认设备连接后再执行。仓库中的 `iOS/README.md` 说明 iPhone 配套客户端的构建方式及限制。

## 界面与数据

菜单栏显示应用入口和未读短信数。主窗口集中显示短信、电话、联系人与基础状态；诊断日志和高级功能位于“设置与高级”。短信以联系人或号码分组，可直接回复、存为联系人；最近通话支持回拨和批量删除。号码归属地由离线规则估计，携号转网后可能不准确。

短信、联系人和通话记录保存在 `~/Library/Application Support/com.quectel.ec20companion/ec20companion_v2.sqlite3`，**不在仓库内**。发布日志、截图或报错前，请自行检查手机号、短信内容、ICCID、IMSI、IMEI 和配对信息。

### SIM 短信容量

EC20 会从模块存储区 `ME` 和 SIM 存储区 `SM` 同步短信到本地 SQLite，但**同步不会自动清空 SIM**。如果 SIM 只有 50 条容量，存满后仍可能无法接收新短信。当前删除操作会连同应用中的本地记录一起删除，尚未实现“核对本地备份后仅删除 SIM 副本”的自动归档。重要短信请另行备份，再按需清理 SIM 中的旧短信。

## 已知限制

- 没有对外发短信、运营商通话和双向语音做完整实机验收；这些操作可能产生运营商费用。请只向自己控制的号码测试。
- 蜂窝网络开关可能影响 macOS 路由；此前出现过关闭后 Wi-Fi 上网异常，后续未继续做蜂窝网络测试。建议保持现有网络设置，先使用短信和电话功能。
- iPhone 客户端需要 Mac 与 iPhone 在同一局域网，Mac 网关默认关闭；没有后台 VoIP 推送，也没有把通话音频传到 iPhone。iOS 源码尚未完成真机验收。
- 本项目不是系统级电话服务，无法保证与 macOS/iPhone 原生“电话”“信息”应用互通，也不承诺支持其他 EC20 硬件版本。

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `Sources/EC20App` | macOS 菜单栏和中文 GUI |
| `Sources/EC20Core` | AT 控制、短信、SQLite、网络状态和网关 |
| `Sources/EC20Transport` | `libusb` 传输与语音桥接 |
| `Sources/EC20BridgeProtocol` | iPhone 局域网协议与加密会话 |
| `Sources/EC20Tests` | 离线模拟测试 |
| `iOS/` | iPhone 配套客户端源码与说明 |
| `scripts/` | 构建、诊断与图标生成脚本 |

欢迎提交 Issue，说明 EC20 型号、macOS 版本、复现步骤及**脱敏后的**日志。目前仓库尚未选择开源许可证；在许可证明确前，请先联系仓库所有者确认再分发修改版。
