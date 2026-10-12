# B站加速 · iOS

**人在海外，iPhone 上的 B站 不再卡在缓冲。**

在海外看冷门视频、4K、HDR，一开就转圈？海外节点没有缓存，单条连接回国取数据太慢。B站加速 把「线程撕裂者」的多线程下载装进了 B站 App：直接从大陆节点取数据，一个视频拆成许多小块同时下载，再按顺序交给播放器。

## 效果

海外网络，同一个冷门 4K HDR 视频，同一台 iPhone：

|          | 下载速度                   |
| -------- | ---------------------- |
| 原版 App   | 0.88 Mbps              |
| **B站加速** | **25.75 Mbps（约 29 倍）** |

播放中连续加速 440 MB，无回退，数据逐字节校验一致。仅为单台设备、单一网络的实测，仅供参考。

## 使用

装好即开启，默认「海外模式」。

屏幕边缘有一个粉色小球，闲置 3 秒自动缩进屏幕边缘，横屏全屏时自动隐藏，不挡画面。点它切换模式，拖动可换位置：

| 小球 | 模式 | 适合 |
| --- | --- | --- |
| 海 | 海外模式 | 人在海外（推荐，已实测） |
| 国 | 国内模式 | 人在国内（实验性，未经国内实测） |
| 关 | 关闭加速 | 与原版 App 完全一致 |

切换后，新打开的视频生效。

## 安装（侧载）

需要：iOS 15 及以上的 iPhone、一台 Windows 或 Mac 电脑、一个 Apple ID（免费即可）。

本项目只发布加速插件，不分发 B站 App 本体。你需要下载两个文件：

| 文件 | 来源 |
| --- | --- |
| B站 8.89.0 安装包 `BiliBiliMApp_8.89.0.v3.1.0.ipa` | [TouchFriend/BiliBiliMApp 3.1.0](https://github.com/TouchFriend/BiliBiliMApp/releases/tag/3.1.0) |
| 加速插件 `BiliAccel-v1.0.dylib` | 本项目 [Releases](../../releases) |

1. **装 Sideloadly**：从 [sideloadly.io](https://sideloadly.io) 下载安装。Windows 还需安装 Apple 的 iTunes 或「Apple 设备」App，让电脑识别 iPhone。
2. **连接手机**：数据线连接 iPhone，手机上点「信任此电脑」。
3. **放入安装包**：打开 Sideloadly，把 `.ipa` 拖进去，填写 Apple ID。
4. **注入插件**：点 **Advanced options**，勾选 **Inject dylibs/frameworks**，点 **+dylib/deb/bundle** 选择 `BiliAccel-v1.0.dylib`。
5. **签名安装**：点 **Start**，按提示输入 Apple ID 密码与验证码。
6. **信任证书**：iPhone 进入「设置 → 通用 → VPN 与设备管理」，信任你的 Apple ID。
7. **开发者模式**（iOS 16 及以上）：「设置 → 隐私与安全性 → 开发者模式」打开并重启。

打开 App，屏幕边缘出现粉色小球即安装成功。

> 免费 Apple ID 签名有效期 **7 天**，到期后用同样的两个文件重复第 3–5 步即可续签，登录状态保留。

## 说明

- 只加速视频，音频保持原样。
- 加速不稳时会自动退回 App 自带下载，保证照常播放。
- 仅支持 B站 iOS 8.89.0。
- 不记录任何网址、Cookie 或账号信息。
- 非官方实验项目，不绕过会员、登录、地区、清晰度或版权限制。

## 致谢

- 本项目基于 [MrTangLuyao/Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper)（线程撕裂者）开发，iOS 版在 App 内原样运行其桌面版下载核心。电脑浏览器用户请直接使用原项目。
- B站 8.89.0 安装包来自 [TouchFriend/BiliBiliMApp](https://github.com/TouchFriend/BiliBiliMApp)。

## 开源协议

MIT，沿用原项目协议。
