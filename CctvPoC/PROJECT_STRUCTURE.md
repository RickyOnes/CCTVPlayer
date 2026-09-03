# TVPlayer（央视频直播壳）项目结构说明

> 生成日期：2026-08-30
> 应用名：TVPlayer（HarmonyOS 电视直播）
> bundleName：`com.RickyOne.TVPlayer` · versionName：`1.0.8` · versionCode：`1000000`

---

## 一、项目概述

TVPlayer 是一款面向 HarmonyOS（OpenHarmony / API 12+）的电视直播应用，依托央视频公开直播源，
提供 CCTV 全系列、中国教育台、全国 30+ 省级卫视共 70+ 频道的直播观看。

核心播放链路：**ArkWeb（HTML5 `<video>`）→ hls.js → CMG WASM 解密 → 视频渲染**。
鉴权、签名、EPG 均由本地 ArkTS 代理完成（`common/` 模块），经 `postMessage` / `runJavaScript` 与 Web 壳双向通信。

- 适配形态：手机 / 平板 / PC（2in1 二合一）
- 支持：后台锁屏播放、横屏窗口分栏、手动全屏沉浸式、台标、节目条（EPG）

---

## 二、目录结构（清理后）

```
CctvPoC/
├── AppScope/                             # 应用级配置（bundleName/版本/图标）
│   ├── app.json5                         # com.RickyOne.TVPlayer，1.0.8
│   └── resources/base/
│       ├── element/string.json
│       └── media/                        # app_icon.png / background.png / foreground.png
│                                         #   / startIcon.png / layered_image.json（分层图标）
│
├── entry/                                # 主模块（唯一 HAP）
│   └── src/main/
│       ├── module.json5                  # 权限、EntryAbility、backgroundModes=audioPlayback
│       ├── ets/
│       │   ├── entryability/EntryAbility.ets   # Ability 入口（Web 加载、backup 扩展）
│       │   ├── pages/Index.ets                 # ★ 主页面（约 99KB，UI + 状态机 + 桥接核心）
│       │   └── common/                         # ★ 本地代理/业务模块（10 个）
│       │       ├── ArktsProxy.ets       # ArkTS↔Web 桥接（runJavaScript / postMessage 封装）
│       │       ├── CctvConfig.ets       # 全局配置（UA、域名、常量）
│       │       ├── CctvHttp.ets         # HTTP 客户端（getText / post，DNS 预热）
│       │       ├── ChannelList.ets      # 频道列表（70+ 频道、台标、pid）
│       │       ├── CmgInject.ets        # CMG WASM 解密注入（jsdecLive8 / worker）
│       │       ├── ProxyClient.ets      # ★ 鉴权客户端（/auth 缓存、ensureAuth、预热节流）
│       │       ├── ProxyEpg.ets         # 节目单（EPG）获取
│       │       ├── ProxyLauncher.ets    # 启动流程编排（代理就绪检测、预热）
│       │       ├── ProxySigner.ets      # 请求签名（防重放）
│       │       └── RawfileDeploy.ets    # rawfile 资源部署/读取
│       └── resources/
│           ├── base/
│           │   ├── element/             # color.json / float.json / string.json
│           │   ├── media/               # ★ 66 个 PNG（频道台标 + 控件图标）
│           │   └── profile/             # backup_config.json / main_pages.json
│           ├── dark/element/color.json  # 深色模式
│           └── rawfile/                 # ★ 运行时原始资源
│               ├── cacert.pem           # CA 证书
│               ├── CMGPlayer.json       # CMG 播放器配置
│               ├── sapi_cache/          # CMG 解密资源（预部署缓存）
│               │   ├── assets_2025_wasm_cmg.worker.js
│               │   ├── assets_2025_wasm_hls.cmg.js
│               │   ├── cmg.wasm
│               │   └── eb_prog.bin
│               └── web/                 # ★ Web 播放壳
│                   ├── player.html      # 播放状态机（hls.js + CMG + mediaSession）
│                   ├── ts_module_body.js# CMG TS 解密模块
│                   ├── keygen_bg.wasm   # 密钥生成 WASM
│                   └── RJq7sO71JF.wasm  # 解密 WASM
│
├── entry/src/mock/                      # mock-config.json5（调试 mock）
├── entry/src/test/                      # 本地单元测试（List.test.ets / LocalUnit.test.ets）
├── entry/src/ohosTest/                  # OHOS 测试（module.json5 + ets/test/*）
│
├── hvigor/hvigor-config.json5           # 构建器配置
├── hvigorfile.ts                        # 构建脚本
├── build-profile.json5                  # 构建配置（签名/产物）
├── code-linter.json5                    # 代码 lint 规则
├── oh-package.json5                     # 依赖声明（modelVersion 6.1.1）
├── oh-package-lock.json5                # 依赖锁
├── local.properties                     # 本机 SDK 路径（本机专属，不入库）
│
├── signatures/                          # ★ 签名材料（勿丢，上架/重签必需）
│   ├── TVPlayer.cer / TVPlayer.csr / TVPlayer.p12 / TVPlayerRelease.p7b
│   └── material/...                     # 签名素材
│
├── app_intro.md                         # 应用介绍（上架文案）
├── PROJECT_STRUCTURE.md                 # 本文档
└── .gitignore
```

### 可再生成 / 工具目录（不参与构建，可忽略）

| 路径 | 说明 |
|---|---|
| `build/` | Hvigor 构建产物，可删除重建 |
| `oh_modules/` | 依赖缓存，`ohpm install` 重建 |
| `.hvigor/` | 构建器缓存，可删除 |
| `entry/.preview/` | 预览器缓存，可删除 |
| `.appanalyzer/` `.codegenie/` `.freebuff/` | IDE 工具目录 |
| `.codebuddy/` | AI 辅助工作记忆（勿删，含跨会话上下文） |

---

## 三、核心模块职责

### 1. `pages/Index.ets`（主页面，最核心）

- **UI**：视频区 + 频道列表分栏、节目条、全屏/横屏布局、台标、媒体控制卡片。
- **状态机**：IDLE → PREPARING → BUFFERING → PLAYING / RECOVERING / ERROR。
  - 首帧超时 35s；恢复分 4 次，第 2 次起经 ArkTS 重新鉴权刷新 m3u8。
- **桥接**：`postMessage`（Web→ArkTS）+ `runJavaScript`（ArkTS→Web）双向驱动。
- **音频会话**：`setAudioSessionConcurrency()` 切换 MIX/PAUSE 并发模式；
  电话打断依赖 `Web.mediaOptions({ resumeInterval: -1, audioExclusive: false })` 自动续播。
- **预热心跳**：`startWarmHeartbeat()` 每 90s 调 `warmDnsIfStale()` 保持鉴权链 DNS/连接常热。

### 2. `common/ProxyClient.ets`（鉴权客户端）

- `/auth` 鉴权缓存：双阈值（年龄 45s / 空闲 30s）+ 5min 绝对 TTL 三重判定。
- `ensureAuth(pid)`：查缓存 → 复用在途请求 → 发起并写缓存，按 pid 去重。
- `markAuthUsed()`：`get_live_info` 成功后刷新 `lastOk`。
- 预热：`warmDns()` / `warmDnsIfStale(threshold)`，`WARM_STALE_MS = 3min`。

### 3. Web 壳（`rawfile/web/player.html`）

- HTML5 `<video>` + hls.js + CMG WASM 解密。
- `__playWithAudio()` / `__toggleMute()` / `__armUnlock()`：声音状态与手势解锁。
- `navigator.mediaSession.metadata`：标题/艺术家同步（锁屏卡片文本）。
- 与 ArkTS 通过 `__post({type:..., ...})` 上报状态。

### 4. 签名 / 鉴权链路

```
冷启动 → warmDns（预热 5 域名）
  → /auth（open-token）→ 缓存
  → /get-live-info → markAuthUsed
  → m3u8 获取 → 签名 → hls.js 拉流 → CMG 解密 → 首帧渲染 → PLAYING
```

---

## 四、关键约束与易踩坑（务必遵守）

1. **绝不手动 `createAVSession`**：ArkWeb 播放 HTML5 video 会自动创建系统媒体会话，
   应用侧再手动创建会冲突（一个应用仅一个会话）→ 媒体卡片整体消失（已三次真机复现）。
2. **音频焦点合规**：官方要求始终 SHARE（MIX_WITH_OTHERS），不能正常播放时用 PAUSE 独占。
3. **沉浸式 API 只用一套**：全屏用 `setWindowLayoutFullScreen(true)` + `setWindowSystemBarEnable([])`，
   退出用反向。**绝不混用 `setImmersiveModeEnabledState`**（两套"或"机制混用会导致退出全屏后
   导航栏不恢复、布局算错）。
4. **媒体资源名只允许 `[a-zA-Z0-9_]`**，禁 `-` `+` 中文；图标须为真实 PNG（文件头 `89 50 4E 47`），
   避免 webp 伪装、避免重复扩展名（如 `xxx.png.png`）。
5. **图片读取**：`getMediaBase64ByName()` 返回纯 base64，需自行拼 `data:image/png;base64,` 前缀。
6. **退出全屏是异步过渡**：`windowRect` 会渐变，需多次 `setTimeout` 重算布局（150/450/900ms）。
7. **心跳间隔必须 < 预热阈值**：否则 `now-last < threshold` 恒成立导致永不预热。
8. **`resumeInterval: -1`**：电话打断后自动续播（`0` 表示不续播，`>0` 为限时续播）。

---

## 五、构建与运行

```bash
# 安装依赖（首次）
ohpm install

# 构建 HAP
hvigorw assembleHap --mode module -p product=default

# 签名
# 使用 signatures/ 下的 TVPlayer.p12 + TVPlayerRelease.p7b（DevEco Studio 自动配置）
```

- 设备形态：`phone` / `tablet` / `2in1`
- 权限：`INTERNET`、`ACCESS_NOTIFICATION_POLICY`、`KEEP_BACKGROUND_RUNNING`
- 后台模式：`backgroundModes: ["audioPlayback"]`（锁屏/后台不被回收）

---

## 六、备份与版本历史

| 文件 | 说明 |
|---|---|
| `CctvPoC.rar` / `entry.rar` / `entry-old.rar` / `Index-ok.rar` | 历史旧备份压缩包（可删除，已由下方 tar.gz 取代） |
| `d:\TV\CCTV\backup_CctvPoC_20260830_clean.tar.gz` | ★ 本次清理后完整源码备份（含本文档） |
| `d:\TV\CCTV\backup_CctvPoC_20260830.tar.gz` | 清理前源码备份（含已删除的根目录 .ets 副本） |

> 说明：根目录原本存在 12 个 `.ets`/`.ts` 冗余副本（ArktsProxy.ets 等）与空文件 `_verify_cmg.cjs`，
> 均为 `entry/src/main/ets/common/` 下正式文件的旧版本或废弃文件，已于 2026-08-30 清理删除。
> 真正参与编译的只有 `entry/src/main/ets/**`。
