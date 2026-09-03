# 央视频定制 APP 技术白皮书 · V6.0

> 版本：2026.09 V6.0
> 适用人群：具备 C# / HTTP / WebView2 / 一定逆向基础的开发者
> 目标：在自有 C# 应用中实现央视频直播**纯净播放**（**不导航官网**、**无黑屏、无花屏、无重载**），并给出**桌面 + 鸿蒙双端**可落地架构。
>
> ⚠️ **V6.0 是一次"推翻式"修订**：2026-08-31 ~ 09-03 的重新逆向**推翻了 V5.0 中多条"铁证级"结论**（最关键的一条：**根本不需要真实导航官网**）。正文中每处被推翻的地方都用 `★ 2026-09 更正` 标注。**请勿再引用 V5.0 的旧结论**。

---

## 〇、最重要的结论（一句话版）

目标已达成：**从各字段参数破解、请求测试，到桌面与鸿蒙双端正常播放**，且**全程不跳转央视频官网**。

### ★ 2026-09 被推翻的旧结论（务必先读）

| V5.0 旧结论 | 2026-09 实证结果 | 状态 |
|---|---|---|
| 花屏根因 = wasm 用 **`self.location.href`（C++ 绑定、JS 不可改写）** 作种子，故只能真实导航官网 | wasm 取 location 的**唯一出口是 `eval()`**（`_emscripten_asm_const_ii`，全模块仅 1 处；表达式仅 `self.location.host/href/protocol`）。**`eval` 是普通全局函数，可 hook** | ❌ **推翻** |
| 真正种子是 `self.location.href` | 真正进入 wasm 的种子是 **`self.activeURL`**（JS 层普通属性）：`moduleDecData` 每次把 activeURL 的 charCodes **追加到 NALU 之后**（长度 `jL` 单独传参） | ❌ **推翻** |
| 必须导航 `yangshipin.cn` | 本地 `127.0.0.1` + **WEVAL（eval hook）** + **emval `origin` Proxy** + 预置**完整** `FAKE_HREF`（43 字符含域名）即可解密 | ❌ **推翻** |
| `[DISP-INIT] Cannot assign to read only property 'activeURL'` = WebView2 限制 | 是**我们自己的 bug**：`defineProperty` 缺 `writable:true` → 只读 → 抛错被 `catch{}` 吞 → 密钥派生中断 | ❌ **推翻** |
| eval 域名劫持（theAnswer）"部分通过但**非根因**" | 它恰恰是**正解的一部分**（WEVAL hook） | ❌ **部分推翻** |
| wasm 只导出 Live 解密路径、**无 VOD/回看解密** | wasm 导出 **`_CMG_jsdecVOD0..8`**（`na..va = func[73..105]`）；`StaticCallModuleVod` 10 个方法、`StaticCallModuleVodMap=[0..6]` 齐全 | ❌ **推翻** |
| 回看做不了是因为"没有 VOD 解密入口" | 回看真正缺的只是**移动端 m3u8 接口**，**不是解密能力** | ❌ **推翻** |
| 纯 Node 无法解密（"依赖浏览器环境"） | `ab_test.cjs` 实证：官方 `fG` 在 **Node 解密 5/5 成功**；成败差异 = 解密时的 `activeURL`（`jL` 长度） | ❌ **推翻** |
| 方案 B（wasm2c 原生解密）"死刑 / 被否定" | `run_out27` 决定性实验：**6/6 帧逐字节 == Node 官方输出**；此前"被否定"是 **harness bug 造成的假阴性** | ❌ **推翻** |
| 不手动 `createAVSession`，靠 `navigator.mediaSession.metadata` 也能出台标 | 日志 `artwork 已设置` 正常但系统媒体卡**始终无台标** ⇒ **ArkWeb 不把 MediaSession artwork 桥接到系统 AVSession**。2026-09 多轮修改全无效 | ❌ **推翻** |
| 手动 `createAVSession` 会导致媒体卡片消失（"三次复现"） | 真因是**没 catch `6600101`**（ArkWeb 可能已先创建）；正确处理 6600101 后，**手动 create 是台标的唯一可行方案**（用户实测"完美解决"） | ❌ **推翻** |

### 战役总览（按攻破顺序）

1. **第一战役 · 请求参数破解**（2026-07-12 ~ 07-13）
   破解 auth / live / cKey / yspticket / sessionToken / seqid 全部字段与签名算法，让 `get_live_info` 返回 `code:0` 并拿到 m3u8 地址。
2. **第二战役 · 网络层修复**（2026-07-13）
   解决 CORS / TLS 指纹 / PNA 导致的 `networkError`，用本地 Go 代理做同源托管 + 媒体转发。
3. **第三战役 · 视频解密攻破**（2026-07-13 晚 ~ 07-15）
   破解 CMG 的 wasm 逐 NALU 解密机制，定位「密钥种子」这一隐蔽根因，让 IDR/P/B 帧全部解密成功、画面正常。
4. **第四战役 · 长期播放衰减与自愈**（2026-07-16）
   破解 wasm 内部 ~750 帧计数器导致的 30s 马赛克花屏（临时方案：C# 自动重载）。
5. **第五战役 · VMPATCH3 内存热修补**（2026-07-16）
   周期性还原 wasm 线性内存，计数器永不累积 → **无花屏、无黑屏、无重载**。
6. **★ 第六战役 · 种子真相重审 → 不再导航官网**（2026-08-31 ~ 09-01）
   推翻"location.href C++ 绑定"旧结论，定位 `eval` / `activeURL` / `self.origin` 三条真实路径 → **本地 127.0.0.1 即可解密**（见 §十）。
7. **★ 第七战役 · 源文件瘦身 slim**（2026-09-01）
   `cmg.worker.js` 1.3MB → `cmg.slim.js` 186KB + `eb_prog.bin` 378KB + `reloc_table.bin` 40KB ≈ **604KB**（见 §十一）。
8. **★ 第八战役 · 鸿蒙 ArkWeb 落地 + 媒体卡片台标**（2026-09-01 ~ 09-03）
   `CctvPoC` 真机换台正常；台标真凶 = **MediaSession metadata 推送时机**（见 §十二）。
9. **★ 第九战役 · 方案 B（wasm2c 原生解密）可行性判定**（2026-09-02）
   解密核心**已证实可脱离浏览器正确工作**；但整体仍冻结，瓶颈在 AVPlayer 集成侧（见 §十三）。

**仍然成立的两条铁律：**
- 20401 根因：`yspsdksign` 的 `sig2` 必须用 `sessionToken`（`/web/open/token`）而非 `authToken`，两套 token 互不相通。
- **解密 ≠ 解码，两者永远都要**：解密 = cmg.wasm 把混淆 NALU 还原成标准 H.264 压缩码流（仍非像素）；解码 = 把 H.264 解码成画面。

---

## 一、整体架构

```
CCTVPlayer (C# / WPF / WebView2)
  ├─ MainWindow.xaml.cs
  │    ├─ ★ 2026-09 更正：默认导航 http://127.0.0.1:18888/player（本地）
  │    │     不再跳转官网。启动参数 --nav=official 可切回官网导航做 A/B 对照。
  │    ├─ WebResourceRequested 拦截（仅官网导航模式下才真正触发）：
  │    │     yangshipin.cn 主文档  → 返回本地 player.served.html
  │    │     yangshipin.cn/sapi/*  → 代理 http://127.0.0.1:18888/sapi/*
  │    └─ 注入 cKey / yspticket base64 到 player.html
  │
  ├─ player.html (WebView2 内运行)
  │    ├─ 加载 /sapi/assets/2025/wasm/hls.cmg.js  (CMG 解密器，同源，704KB 保留)
  │    ├─ ★ 2026-09 更正：cmg.worker.js(1.3MB) 已由 slim 解密层取代，见 §十一
  │    │     cmg.slim.js 186KB + eb_prog.bin 378KB + reloc_table.bin 40KB ≈ 604KB
  │    ├─ ★ 三大种子补丁（取代"真实导航"）：
  │    │     ① WEVAL —— hook window.eval，拦 self.location.host/href/protocol
  │    │     ② emval origin Proxy —— 拦 __emval_get_global('origin') → https://yangshipin.cn
  │    │     ③ activeURL 预置完整 FAKE_HREF（43 字符含域名，writable:true）
  │    ├─ fetch/XHR 透明改写 → 媒体全走 /media 代理
  │    └─ hls.js + CMG 播放器解密 TS 分片
  │
  └─ cctv-proxy (Go, main.go)  ← 本地代理，127.0.0.1:18888
       ├─ /sapi/<path>   反代 sapi.yangshipin.cn（改写同源 + 注入诊断）
       ├─ /media?u=<CDN> utls Chrome 指纹抓取 m3u8/TS/key，回传 + CORS
       ├─ /player        托管 player.served.html
       ├─ /open-token    转发 h5access 拿 sessionToken
       └─ sapi_cache/    磁盘缓存上游响应（注入响应时应用）
```

**密钥/签名三件套的来源：**
- `authToken`：来自 `/auth`，仅作网关层 `yspplayertoken` 头。
- `sessionToken`：来自 `/web/open/token`，是算 `sig2` 的真正密钥。
- `cKey` / `yspticket`：WebView2 内用浏览器原生 V8 动态生成（纯 JS / 复刻 wasm），不依赖官网页面。

---

## 二、第一战役：请求参数破解（按攻破顺序）

### 2.1 两套完全不同的签名体系（最大认知错误）

之前误以为「所有签名都靠 wasm」，这是 401 的根因。真实情况有**两套独立体系**：

| 体系 | 用途 | 算法 | 是否用 wasm |
|------|------|------|------------|
| **AUTH 签名**（函数 `su`） | `/auth` 请求体签名 | 盐化 MD5（盐 `Ac`），字段按字母序拼接 | **否** |
| **LIVE SDK 签名**（函数 `au` / `xs`） | `get_live_info` 的 body 签名 + `yspsdkinput` | 盐化 MD5（盐 `Tc`）/ 无盐 MD5（`localeCompare` 排序） | body 部分否；`yspsdksign` 头用 wasm |
| **yspsdksign 头**（`sig2`） | `get_live_info` 的 sdk 头 | `keygen_bg.wasm` 的 `get_signature` | **是** |

> ⚠️ 排序陷阱：`au`/`su`（body 签名）用 JS 默认 `Array.sort()`（按 UTF-16 码点 = Ordinal）；`xs`/`ne`（`yspsdkinput`）用 `String.localeCompare` 排序——**两者不同，切勿混用**。

### 2.2 auth 签名（函数 `su`，纯 MD5，无 wasm）

请求：`POST https://player-api.yangshipin.cn/v1/player/auth`

```
s = "appid=ysp_pc&guid=<guid>&pid=<pid>&rand_str=<rand_str>"
signature = md5( s + Ac )
body = "pid=<pid>&guid=<guid>&appid=ysp_pc&rand_str=<rand_str>&signature=<signature>"
```

- 盐 `Ac`：生产 `"n@7QKk%YeSjfw%22"`，测试 `"PUlOFD%XM9jEdvuR"`（URL 含 `test=on`）。
- `rand_str` 字母表：`"ABCDEFGHIJKlMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"`（大写 K 后是小写 L，不是数字 1），取 10 字符。
- 黄金验证：用真实 HAR 反算 `md5(...+Ac)` 与 HAR 中 `signature` 完全一致 ✅。

### 2.3 live body 签名（函数 `au`，纯 MD5，无 wasm）

```
1. 把所有字段（含 rand_str，不含 signature 本身）按 JS 默认 Array.sort() 拼成 k=v&k=v...
2. signature = md5( 上述拼接串 + Tc )
```

- 盐 `Tc`：生产 `"0f$IVHi9Qno?G"`，测试 `"62fb5e14f246f"`。
- 黄金验证：用真实 `get_live_info` 请求算出 `md5=6891575e8cec600a31c763e68be0015a` 与 HAR body 的 `signature` 一致 ✅。

### 2.4 yspsdkinput（函数 `xs`/`ne`，无盐 MD5，无 wasm）

```
1. 把 body 字段按 String.localeCompare 排序拼成 k=v&...（调用 xs() 时 body 尚未写入 rand_str/signature，二者天然不参与）
2. rnd = md5( 上述拼接串 )   ← 无盐
```

- 该 `rnd` 同时作为 `yspsdksign` 中 `-rnd-` 那段，也是 wasm `get_signature` 的 input 首段。
- 黄金验证：用真实 HAR 算出 `rnd=364e7007be98cafbdcb5950778dfa85d` 一致 ✅（必须用 `localeCompare`，用 Ordinal 会算错）。

### 2.5 cKey 生成（2026-07-12 攻破，纯 JS，无 wasm）

`cKey` 结构：前缀 `"--01"`（4 字符）+ 320 个十六进制字符（=160 字节密文）= 共 324 字符。

- 由官方 webpack 模块 `fb15`（`chunk-vendors.86ef4b5a.js`）内的函数 `ts(cnlid, tsSec, version, guid, platform)` 生成。
- 该模块自包含，内联加密库 `yt`（CryptoJS 风格），**不调用任何 wasm**。
- **完全确定性**（无 `Math.random` / `Date.now` / `new Date`，已核验计数=0）：只要环境输入一致即可复现。
- 输入：`document.URL`、`navigator.userAgent.toLowerCase()`、`document.referrer`（仅当长度 > 阈值才取）。
- C# 集成：把 `ts_module_body.js` 以 base64 注入 `window.__ckeyCoreB64`，用 env-stub 提供上述 DOM 输入，`window.__genCKey(...)` 取回结果。
- ⚠️ `tsSec` 是秒级时间戳，须**每次请求实时生成**，否则过期返回 401。

### 2.6 yspticket 生成（2026-07-12 攻破：复刻 `_c` + `RJq7sO71JF.wasm`）

`_c(livepid, ts, cnlid, guid, yspappid, appVer)`，其中 `ts` = 认证响应 `data.ts`（秒级时间戳，**不是 token**）。

- 明文布局（导出 `_get_encrypt_str_len` 权威返回 = 62 字节）：
  `livepid(9) + 分隔符 + ts(10) + 分隔符 + guid(20) + 分隔符 + yspappid(9) + PCG尾缀(11)`
- `cnlid` / `appVer` 虽传参但**不进入明文**（XOR 变异法验证）。
- AES-CTR 密钥/IV 是 wasm 内常量 → 密钥流恒定；改任一输入字段只翻转其自身对应密文。
- **PCG 尾缀（11 字节随机）最关键**：wasm 的 `func705` 用 import `d = Emscripten _time`（`Date.now()/1000`）作 PCG 种子。复现：把 `_time` import 固定喂入认证返回的 `ts`（秒），即得与官方一致尾缀。
- wasm 导入（module `a`，Emscripten 风格，29 个函数）：
  - `a.O = is_browser_environment` → 必须返回 1，否则走非浏览器分支（结果错）。
  - `a.d = _time(ptr)` → 把 seed(ts) 写入 ptr 并返回 seed（PCG 种子）。
  - 其余 import 一律返回 0 即可。
- 导出：`T=_aes_encrypt_ctr`、`R=_malloc`、`S=_get_encrypt_str_len`、`W=_free`。
- C# 集成：把 `RJq7sO71JF.wasm` 以 base64 注入 `window.__yspTicketWasmB64`，`window.__genYspTicket(...)` 在浏览器 V8 实例化并算 62 字节 hex。
- ⚠️ `ts` 取自认证响应 `data.ts`，须**每次实时生成**，切勿硬编码旧值。

### 2.7 sessionToken 获取（2026-07-13 攻破：20401 根因修复）

**为什么需要它**：`yspsdksign` 头的 `sig2` 由 `keygen_bg.wasm` 的 `get_signature` 产出，其 `state.token` 必须填 `sessionToken`，而请求头 `yspplayertoken` 用的是 `authToken`——**两套互不相通的 token**。

获取流程（两步）：
1. `rnd = wasm.get_token_rnd()`（与 `get_signature` 同 wasm，PCG 随机生成，无需外部参数）。
2. `GET https://h5access.yangshipin.cn/web/open/token`，Query：
   `yspappid=519748109 & guid=<guid> & vappid=59306155 & vsecret=b42702bf7309a179d102f3d51b1add2fda0bc7ada64cb801 & raw=1 & version=v1 & ts=<毫秒时间戳> & rnd=<上面结果>`
   响应：`{ "code":0, "data":{ "token":"<sessionToken>" } }`
3. `sig2 = wasm.get_signature(input)`，其中 `input = rnd + "-" + guid + "-" + seqid + "-" + requestid`，`state.token = sessionToken`。
4. `yspsdksign = sig2 + "-" + rnd + "-" + guid + "-" + seqid + "-" + requestid`。

> ★★★ 20401 根因：之前把所有签名都喂 `authToken` → `sig2` 校验失败 → 20401「获取直播信息失败」。用 `sessionToken` 算 `sig2` + `authToken` 作 `yspplayertoken` 头 → 端到端 `code:0`。

### 2.8 seqid 持久化（2026-07-13 攻破）

- `seqid` 是**客户端持久计数器**：浏览器存于 Cookie/localStorage，删 cookie 才归 1，否则跨天/跨次递增；服务器校验 seqid **不回退**，复用旧值 → 20401。
- 之前 app 每次重启用固定 `seqid=2` 复用旧值 → 20401。
- 修复：app 把 seqid 写入本地文件 `seqid.state`，跨运行**单调递增、永不复用旧值**；`auth` 与 `live` 的 `seqid` / `Cookie.nseqId` 始终一致。删除 `seqid.state` 即「全新初始值 1」（相当于浏览器清 cookie）。

### 第一战役 · 注意事项（踩坑集）

1. **auth 绝不用 wasm**：之前误用 `get_signature` 签 auth 是 401 根因，务必用 `su` 盐化 MD5。
2. **两套 token 互不相通**：`yspplayertoken` 头用 `authToken`，`sig2` 用 `sessionToken`。
3. **排序算法三选一别混**：`su`/`au` = Ordinal；`xs`/`ne`(`yspsdkinput`) = `localeCompare`；`yspsdksign` 的 `rnd` 段也用 `localeCompare` 结果。
4. **时效值必须实时生成**：`cKey`(含 tsSec) / `yspticket`(含 auth ts) / `authToken` / `sessionToken` 过期必 401。原样重放几小时前的 cKey 必失败（这**不是算法错，是过期**）。
5. **auth 与 live 的 `rand_str` 是两个不同的随机串**，不要混用。
6. **`ts` 参数语义**：`yspticket` 的 `_c` 第二参是认证响应 `data.ts`（秒），**不是 token**。

---

## 三、第二战役：网络层修复（CORS / TLS / 同源托管）

### 3.1 现象
`get_live_info` 已返回 `code:0`、m3u8 URL 也拿到，但 WebView2 内 hls.js 用 XHR 加载 CDN 时失败：`Failed to fetch` / `networkError` / `manifestLoadError`（resp=0）。

### 3.2 双重根因
1. **CORS**：WebView2 以 `file://`（opaque origin）加载页面，向 `*.cctv.cn` CDN 发 XHR，CDN 不返回 CORS 头 → 跨域被拒。
2. **TLS 指纹**：CDN 要求 Chrome 的 utls 指纹（这正是本地 Go 代理存在的唯一原因），WebView2 真实 Chrome TLS 直连会被拒。

→ 媒体（m3u8 / TS / 解密 key）**必须也走本地 Go 代理**，不能让 WebView2 直连 CDN。

### 3.3 修复（同源托管 + 媒体经代理）

**A) Go 代理 `cctv-proxy` 三个端点（`main.go`）：**
- `/media?u=<CDN URL>`：用 utls Chrome 指纹抓取任意 m3u8/TS/key 并原样回传（带 `Access-Control-Allow-Origin: *`）。
  - **m3u8 相对路径改写**：把相对 URI 按 RFC3986 解析为基于 m3u8 自身 URL 目录的**绝对 CDN URL**（继承 `?svrtime&pid&ysign…` 鉴权查询串），使页面改写函数能捕获并转发到 `/media?u=<绝对CDN URL>`。
  - **Content-Length 必须删**（且在 `WriteHeader` 之前）：改写后响应体变长，保留上游 `Content-Length` 会导致 `ERR_CONTENT_LENGTH_MISMATCH` → hls.js `manifestLoadError`。
  - TS 分片为 1:1 拷贝、长度一致，保留原始 Content-Length 即可。
- `/sapi/<path>`：同源代理 `sapi.yangshipin.cn`（CMG 的 `hls.cmg.js` / `cmg.worker.js`），把响应里的绝对 `https://sapi.yangshipin.cn` 改写为 `/sapi`。
- `/player`：从代理同目录读取 C# 写入的 `player.served.html` 并托管。

**B) C#（`MainWindow.PlayOfficialAsync`）：**
不再 `NavigateToString(html)`，而是把注入了 wasm/cKey/yspticket base64 的 HTML 写到 `player.served.html`，再 `Navigate("http://127.0.0.1:18888/player")`。页面 origin 变 `127.0.0.1:18888`，与 `/media`、`/sapi` 同源。

**C) `player.html` —— 网络层拦截（关键）：**
- 两个 CMG 脚本改为 `/sapi/assets/2025/wasm/...`（同源加载）。
- 早期用 `new Hls({loader: ProxyLoader})` 改写媒体请求，**实测 `hls.cmg.js` 不读该 loader 配置、仍直连 CDN** → 继续报错。故改为在页面顶部 **patch `window.fetch` 与 `XMLHttpRequest.prototype.open`**：任何含 `cctv.cn`/`yangshipin.cn` 的请求透明改写成 `http://127.0.0.1:18888/media?u=<编码后的CDN URL>`；已是 `127.0.0.1`/localhost 的不二次改写。
- 该方案与 loader 实现无关，且**不替换 loader → CMG 自带的 TS 解密逻辑完整保留**。

### 3.4 验证要点
重跑 app 后：`cctv-proxy.log` 应出现 `MEDIA GET <m3u8>` / `MEDIA GET <TS>` / `SAPI GET .../hls.cmg.js` 且均为 HTTP 200；`cctv-debug.log` 应出现 `[net] 网络拦截已安装` 与若干 `[net] xhr→proxy ...` / `[net] fetch→proxy ...`，不再报 `networkError`，最终出现 `播放中`。

---

## 四、第三战役：视频解密攻破（核心，按攻破顺序详述）

> 本战役是整个第一阶段最艰难的部分。下面严格按**实际攻破顺序**记录，便于后人复现思路、避开死路。

### 4.1 现象与初步诊断

播放后**有声音、视频花屏**（音频正常，P/B/IDR 帧花屏）。

**诊断埋点（注入 `hls.cmg.js` 的 `cmgDecNew`/`cmgDecNew2`）：**
```
CMGDEC1#N t=<NALU类型> in=<长度> out=<长度> inh=<前16字节hex> outh=<前16字节hex> same=<Y/N>
```
- `same=Y` = 前 256 字节 out 与 in 全同 = **解密恒等失败**（数据仍是密文）→ 花屏根因。
- `same=N` = 解密确实改变了数据。

**最初实测：所有 40 个 NALU 的 `out` 与 `in` 完全相同 → `fG[wz(0x6bf)]` 返回恒等 → 数据仍是加密状态 → 花屏。**

### 4.2 解密调用点定位（架构澄清）

- `cmg.worker.js`(1.3MB) **不含 decrypt/NALU/license/ccall 任何字符串**，只有 Emscripten 胶水；真正解密在它内嵌的 **wasm 二进制**（导出名被混淆成 `_a`/`_b` 之类）。
- `hls.cmg.js` 里 `fG` 是混淆对象，`fG[wz(0x6bf)]` 是**唯一 NALU 解密调用点**，入参 `(module, ts, nalu, key)`，`key` 来自 `fG[wz(0x9d2)]`(路径1) 或 `fG[wz(0x22f)]`(路径2)，均为 `fG` 的零参方法。
- 解密调用点上下文（`hls.cmg.js` idx≈210867）：
  ```
  jK.forEach(jN => {
    if (void 0 !== jJ[wz(0x97f)] && (            // module 存在
      fG[wz(0x909)](jJ[wz(0x97f)], jJ[wz(0xb0b)].mediaTagId, fG[wz(0xa77)]),  // 每 NALU 都跑 key-init(UpdatePlayer)
      (type5 || type1) && (                      // 仅 IDR(5) 或 P/B(1) 解密
        jJ[wz(0x479)] ? jN.data = fG[wz(0x6bf)](jJ[wz(0x97f)], config[0x291], jN.data, fG[wz(0x9d2)])
                      : jJ[wz(0xb20)] && (jN.data = fG[wz(0x6bf)](jJ[wz(0x97f)], level[0x291], jN.data, fG[wz(0x22f)]))
      )
    )) { case 0x1: ... case 0x5: ... }
  });
  ```
- **双密钥槽（关键事实）：**
  - 路径1（`jJ[0x479]` 为真，IDR/SPS 决定）：key = `fG[0x9d2]`（字符串 `"live"`，转 key_index 43），ts = `jJ['config'][0x291]`。
  - 路径2：key = `fG[0x22f]`，ts = `jJ[0xb0b][0x291]`。
- **`fG[wz(0x909)]` = 控制函数（派发器）**，在 `hls.cmg.js` 里只被调用 3 处：`InitPlayer`(@624643) / `UpdatePlayer`(@210830 每帧) / `UnInitPlayer`(@625107)。它把命令派发到 `CNTVH5PlayerModule.ModuleLive.<方法>`。
- **wasm 导出（从 `CMGDEC1#1` 模块导出全貌 dump 确认）：**
  - `ba=func[71]=_CMG_InitPlayer`、`ca=func[254]=_CMG_UnInitPlayer`、`da=func[176]=_CMG_UpdatePlayer`、`ea..ma=func[91..99]=_CMG_jsdecLive0..8`、`na..va=func[73..105]=_CMG_jsdecVOD0..8`。
- **`func 51`(jsdecLive8 调的 transform) 与 `func 71`(InitPlayer) 都是字节码虚拟机（VM）**：用 `br_table` 做指令分发，从内存缓冲区读「程序」解释执行。恒等 = 该程序读到的**密钥槽空/错**。

### 4.3 死路排查（均已实证推翻，记录以防重蹈）

> 这些是花了大量轮次的假方向，**结论都是「不是根因」**，务必记住别再走。

| 假设 | 验证方式 | 结论 |
|------|----------|------|
| **CMGPlayer.json 缺失** | wasm 数据段含 `https://yangshipin.cn/Library/CMGPlayer.json` 与硬编码 `MD5HEX=A73004463239C524F37849F42DD267EF`；代理加 `/Library/CMGPlayer.json` 路由 | **证伪**：wat 里该字符串是死数据（无函数引用）；代理日志全程 0 次 `/Library` 请求；wasm 根本不 fetch 它。它只是算法开关（VER/RSA/SM2/...），**无密钥**。 |
| **eval 域名劫持（theAnswer）** | 重写 `window.eval`，把 `eval("self.location.host")` 伪装成 `yangshipin.cn` | ⚠️ **★ 2026-09 更正：这条判错了**。`eval` hook **不是死路，而是正解的一部分**。旧判据"绕过域名校验后解密仍恒等"是因为**同时还有另外两个变量没修**（`activeURL` 种子被写成 `replace` 后的 30 字符短串、`self.origin` 经 emval 泄露）。三者齐修后（WEVAL + origin Proxy + 完整 FAKE_HREF），本地 127.0.0.1 解密与导航官网**逐帧等价**。详见 §十。 |
| **`Object.defineProperty(window.location,...)` 伪装** | 在 `cmg.worker.js` 前插入 location getter 伪装 | **彻底失败**：Chromium 中 `window.location` 是 window 实例上的**自有不可配置访问器**，`location.href` 是 Location 实例上的**自有不可配置访问器**——二者都**遮蔽原型**，覆盖 `Location.prototype.href` / `Window.prototype.location` **全部无效**。任何「location 伪装」路线在 WebView2 里都注定失败。 |
| **强制 `global 9=2` wasm 补丁** | 改 `cmg_decrypt.wat` func 99 在 `call 51` 前强制 `global.set 9=2`，重编嵌入缓存 | **有害**：`func 99` 仅在**首次调用**（`global 9 != 2`）时把 4 参存入结构体，之后恒为 2 复用。强制首调即 `==2` → 输出缓冲还空 → `out=0` → 播放失败。撤回。 |
| **强制补调 `mod._CMG_InitPlayer(ctx)`** | 在首次 UpdatePlayer 前直接调 wasm 导出 | **无效**：跳过了派发器 InitPlayer 分支里「把种子 URL 写入 wasm 内存」的前置步骤，wasm 密钥派生(func 71)从未真正执行 → 密钥表空。 |
| **URL 种子注入（v5 三处代码级替换）** | 在派发器注入层把种子全局强制成 `https://yangshipin.cn/...` | **证伪**：三处替换全部注入成功（`[diag] 种子URL#1/#2/#3 已注入`），但仍 `ALL-Y` / `same=Y`。InitPlayer 不读这些 JS 层变量作种子。 |

> ## ⚠️ ★ 2026-09 重大更正：§4.4 ~ §4.8 的历史结论已被推翻
>
> 下面 §4.4 / §4.5 记载的「`self.location.href` 是 C++ 引擎绑定、JS 层不可改写，因此**只能真实导航官网**」——**这条结论是错的**。
> 2026-08-31 ~ 09-01 重新逆向后的**正确结论见 §十（第六战役）**。简版：
>
> 1. wasm 取 location 的**唯一出口是 `eval()`**：`cmg.wat` 中 `call 21`（= import `env.y` = `_emscripten_asm_const_ii`）**全模块仅 1 处**，在 `func[51]`（VM 解释器）内；`ASM_CONSTS[0]` 即 `theAnswer`，数据段里只有 `self.location.host` / `href` / `protocol` 三个表达式。**`eval` 是普通全局函数，可 hook**（WEVAL）→ 无需真实导航。
> 2. **真正进入 wasm 内存的种子是 `self.activeURL`**（JS 层普通属性），由 `moduleDecData` 每次解密时把它的 charCodes **追加到 NALU 之后**（长度 `jL` 单独作为第 4 个参数传入）——**不是** `location.href`。
> 3. **还有第二个泄露点 `self.origin`**：官方 `moduleActive` 的 INITPLAYER 分支第一个取值就是 `self.origin`（优先于 `location.href`），路径是 wasm VM → import `__emval_get_global('origin')` → `globalThis.origin`（真实值）。它**不走 eval**，所以旧 WEVAL hook 的 `/location/` 正则**漏拦**了它。症状特征：**只坏 P/B 帧（t=1），IDR（t=5）正常**。
> 4. 当年那条 `[DISP-INIT] Cannot assign to read only property 'activeURL'` **不是 WebView2 的限制**，是我们自己的 bug：`Object.defineProperty(window,'activeURL',{value:FAKE_HREF,configurable:true})` **缺 `writable:true`** → 属性变只读 → 赋值抛错 → 被 `catch{}` 吞掉 → 密钥派生中断 → 全帧花屏。
> 5. **真实导航官网不是必需的**：本地 `127.0.0.1` + 上述三补丁（WEVAL + emval origin Proxy + 完整 `FAKE_HREF`），解密结果与导航官网**逐帧等价**（见 §10.4 A/B 实测对照）。
>
> 下面 §4.4 ~ §4.8 **保留原文**，作为逆向过程的**历史记录**（其中的现象与日志仍然真实、仍有价值），但**结论与修复方案请以 §十 为准**。

### 4.4 根因锁定（决定性）

**派发器 `fG[0x909]` 的 InitPlayer 分支（`hls.cmg.js` @201443，去混淆）：**
```js
self['activeURL'] = self.location.href || self.activeURL || window[...].href || '' ;
if (self['activeURL'].indexOf('yangshipin.cn') >= 0)
    self['activeURL'] = self['activeURL'].replace('yangshipin.cn', '');
self[flag] = false; self[prop] = '';
jH = jC[_CMG_InitPlayer](jK);   // ★ 真正的 wasm 密钥派生调用
```
- 所有异常被外层 `catch(jN){}` **静默吞掉**（这是反复误判的元凶——InitPlayer 分支体内崩溃我们看不到）。
- 实锤证据链：
  1. `[DISP-INIT] setURLglobal ERR=Cannot assign to read only property 'activeURL'` → 注入的 `self['activeURL']=yangshipin` 被 WebView2 拒绝（只读）。
  2. `[LOC-SPOOF] ... verified=false now=http://127.0.0.1:18888/player` → `self.location.href` 始终真实（127.0.0.1），JS 层无法改写。
  3. 把 `origin`/`activeURL` 都设成与真实站点完全一致（yangshipin.cn）却仍 `ALL-Y` → InitPlayer 读的是 `self.location.href`（C++ 引擎绑定，绕过 JS 原型），**不是** `activeURL`/`origin` 链。
- ~~**★ 铁证结论**~~（**★ 已于 2026-09 推翻，见上文更正块与 §十**）：（历史结论）CMG 解密 wasm 的 `InitPlayer` 用 **`self.location.href`（C++ 绑定，JS 层不可改写）** 作密钥种子。本环境 `location=127.0.0.1:18888/player` → 种子错 → 密钥槽空 → `fG[0x6bf]` 恒等 → 全帧花屏。
  > 保留这段是为了解释**当年为什么会上导航的当**：三者（location / activeURL / origin）在**导航官网时恰好同时正确**，所以导航能work，却把人误导成"location 是唯一真因"。

### 4.5 ~~终极~~修复：C# 真实导航 + WebResourceRequested 拦截（★ 已被 §十 取代）

> ⚠️ **本节方案已被 §十 取代。** 真实导航官网**不再需要**，且已不再是默认路径（默认改为本地 `127.0.0.1:18888/player`）。
> 官网导航仅作为 `--nav=official` 的 A/B 对照与**回退手段**保留。保留本文是因为其 `WebResourceRequested` 拦截实现本身仍然可用。

（历史原文）既然 `location.href` 在 WebView2 里**无法被 JS 改写**，当时的结论是：唯一正解是让 WebView2 **真实导航到 `yangshipin.cn`**，再用 `WebResourceRequested` 把主文档与 `/sapi` 资源替换成本地/代理内容。
> 📌 部分仍然成立的部分：Chromium 中 `window.location` 确实是不可配置的 own accessor，**"伪装 location" 这条路注定失败**——这一点没错。错的是由此推出"只能真实导航"：**我们根本不需要伪装 location，只需 hook `eval` 与 emval 即可**。

**`MainWindow.xaml.cs` 改动：**
1. 导航 URL 由 `http://127.0.0.1:18888/player` 改为 `https://yangshipin.cn/tv/home?pid={cctvCh.Pid}`（在 `PlayOfficialAsync` 内）。
2. `WebResourceRequested` 新增拦截：
   - `yangshipin.cn` 主文档 → 返回本地 `player.served.html`（含 wasm/cKey/yspticket base64 注入）。
   - `yangshipin.cn/sapi/*` → 代理到 `http://127.0.0.1:18888/sapi/*`（保持 Go 注入）。
   - 用 `e.GetDeferral()` + `ServeYangshipinAsync` 异步返回。
3. 因旧 SDK `CreateWebResourceResponse` 属于 `CoreWebView2Environment`，新增字段 `_webViewEnv` 保存 env 引用。
4. `WebResourceRequested` 仅给 `cctv`/`yangshipin` 加 `Referer`（防盗链）。

**`main.go` 改动：**
- `initBlockNew` 移除会污染 activeURL 链的 origin/href/referer/head 强制覆盖与 location defineProperty hack（导航现已提供正确 yangshipin.cn origin），仅保留诊断与 InitPlayer 调用。

> 此修复同时让**第一战役的 cKey/yspticket 生成器**也读到正确的 `document.URL=yangshipin.cn`（它们的算法也读 `window.location.href`），一举两得。

### 4.6 验证：IDR 成功、P/B 仍恒等

重启播放后日志（决定性突破）：
```
[DISP] cmd=UpdatePlayer jD=1784035250712 loc=https://yangshipin.cn/tv/home?pid=600001859  ← 导航拦截生效！
CMGDEC1#1 t=5 (IDR)    same=N  in=105330 out=105326   ← IDR 解密成功（第一帧正常静止画面）
CMGDEC1#2..40 t=1 (P/B) same=Y                        ← P/B 解密恒等（花屏根因）
```
- **结论**：IDR 与 P/B 都走路径1（`key="live"` → key_index 43，IDR 成功）；差异在 NALU 数据 → wasm 内部 `jsdecLive8` 按 NALU 类型分支：IDR 用正确密钥槽，P/B 走恒等/错密钥分支。
- 此时画面表现：**第一帧（IDR）正常静止画面，随后 P/B 帧花屏**。

### 4.7 第二帧（#2）攻坚全过程（v1 ~ v4）

导航修复后，仅 IDR 后**首帧 P/B（#2）** 仍 `same=Y`（#3 起全部 `same=N`）。判定为 wasm 首帧 P/B 密钥槽**异步滞后 1 帧**才就绪。下面是按攻破顺序的 4 次迭代：

**v1 · 同步重试（无效）**
- 在 `cmgDecNew` 注入：P/B 帧解密若输出恒等，立即重调一次 `fG[0x6bf]`。
- 实测：`[RETRY-PB]` 计数=0，仍 `same=Y` → **槽填充跨 tick 异步**，同步重试无效。

**v2 / v2.2 · 缓冲 + 后续帧补解密（FIX-PB）**
- 首帧失败 P/B 的 sample 缓冲到 `window.__cmgPB[__mt]`；下一个成功解密帧（type=1 成功或 type=5 IDR）时回写补解密结果到 `jN[0x944]` 与 `jN['data']`。
- 关键机制确认：`pushAccessUnit` 在 `hls.cmg.js` 的 `parsePES` switch 里是**遇到下一个 IDR/GOP 边界**才把累积的 VideoSample 推出（非逐 sample 实时推）。故 FIX-PB 在 #3 的 forEach 里回写 `jN[0x944]` **早于 #2 的 push** → 写回有机会生效。
- 移除无效的 IDR 预热（PRIME，因填错槽）。

**v3 · IDR 预热 P/B 槽（实测无效）**
- 在 IDR 分支用正确 key（`fG[0x9d2]`）发一次伪 P/B NALU 解密以预热 P/B 槽。
- 实测 `[WARM]` 触发 3 次（`479=true`，用正确 key）但 `#2` 仍 `same=Y` → 证实槽填充**异步**（worker 跨 1 帧才激活），预热填不进。

**v4 · 原地写回修复（当前部署 12180992B）**
- FIX-PB 写回由「重赋值新数组 `jN[0x944]=__fx`」改为「**原地 `.set()` 覆盖原缓冲区**」（长度不符才回退重赋值），打 `inplace=Y/N` 日志。hls.js 的 NALU 单元按引用持有切片，原地覆盖即可让持有引用的 VideoSample 看到正确数据。

### 4.8 最终结论（用户实测 v4，2026-07-15）

- **用户明确：看不到花屏**。日志：40 帧仅 #2 `same=Y`；`[FIX-PB] 补解密成功 #1 len=38828 inplace=false`（走重赋值兜底）；错误日志仅 2 条且均非解码错误（`[LOC-SPOOF]` 是导航伪装诊断、`proto-href:ok` 证密钥种子正确；`[非致命:mediaError/bufferSeekOverHole]` 是 hls.js 直播分段良性缓冲事件）。
- **★ 根因定性修正**：可见花屏的元凶是**导航（`location.href` 密钥种子）问题**（4.4~4.5 已修复，导航后 #1/#3~#39 全 `same=N`）。`#2 same=Y` 只是 IDR 后首帧 P/B 密钥槽**异步滞后 1 帧**的**良性单帧异常**，浏览器原生 H.264 解码器**错误隐藏**（用前后向运动矢量/重复前一帧），不导致可见花屏，也不持续传播（下个 IDR 前重同步）。
- **判定**：任务实质完成，播放干净。`#2` 仅日志层异常，无需再改代码（继续改有回归风险）。

> 可选洁癖项（非必要）：若想日志零异常，需查清 `inplace=false` 原因（`jN[0x944]` 在 FIX-PB 时刻长度/类型与重解密结果不符 → 未走 `.set()`）并让 #2 首帧即解密成功。属非必要优化。

> ### ★ 2026-09 更正：`#2 same=Y` 不是"良性单帧异常"，而是种子没修对的症状
>
> V5.0 把它定性为"密钥槽异步滞后 1 帧的良性异常"，是基于**当时种子仍不正确**这一前提下的观察。
> 2026-09-01 把种子彻底修对（`activeURL` 完整 43 字符 + `self.origin` Proxy）后的 A/B 实测（见 §10.4）：
>
> | 轮次 | 导航 | same=N | same=Y | FIX-PB 失败 |
> |---|---|---|---|---|
> | 修复前 | 官网 | 1199 | **1** | 0 |
> | 修复前 | 本地 127.0.0.1 | 1206 | **1194**（几乎全是 t=1 的 P 帧） | 9378 |
> | **修复后** | **本地 127.0.0.1** | **6013** | **9** | 4 |
>
> 即：`same=Y` 从"每 2 帧就坏 1 帧"降到 **0.15%**，且残余失败帧同属某个子流（`419a28d8...`），是**两种导航方式共有**的、与本地化无关的现象。
> **结论**：`same=Y` 的多寡是**种子是否正确的直接度量**，不要再拿"良性单帧"自我安慰。排查花屏时**第一步就该看 `same=N/Y` 比例**，而不是先怀疑帧序号。

### 第三战役 · 视频解密要领与注意事项（精华）

1. **`same=Y` 的语义**：`same=Y` 仅代表前 256 字节 + 长度相等相同。若 CMG 用**子样本加密**（NALU 前导明文、后段才加密），前 256B（含 NALU 头 + slice_header）本就明文不变 → `same=Y` 可能是正常现象。判读花屏根因必须看**全长逐字节 diff（`diffN`）** 与 **`outh` 首字节是否合法 H264 头（65/41/61/67）**，不能仅凭 `same=Y` 下结论。
2. ~~**密钥种子来自 `self.location.href`（C++ 绑定）**~~ → **★ 2026-09 已推翻，正确版本如下**：
   - 仍然成立的部分：`window.location` / `Location.prototype` 在 Chromium 中确实**不可配置**，"伪装 location" 这条路**注定失败**。
   - **被推翻的部分**：由此推出"只能真实导航官网"是错的。真相是三条路径：**① wasm 取 location 的唯一出口是 `eval()`（可 hook）→ WEVAL；② 真正种子是 `self.activeURL`（JS 普通属性，须预置**完整 43 字符含域名**且 `writable:true`）；③ `self.origin` 经 emval 泄露（不走 eval，须用 Proxy 拦），漏它 = **只坏 P/B 帧、IDR 正常**。**
   - **不需要真实导航官网**，详见 §十。
3. **`catch(jN){}` 静默吞异常是最大干扰**：派发器 InitPlayer 分支体内任何崩溃都被吞掉，导致「InitPlayer 从未真正调用」长期被误判。诊断必须整体 try/catch 暴露真实异常。
4. **双密钥槽**：IDR 走路径1（`fG[0x9d2]="live"`），P/B 走路径1 或路径2（`fG[0x22f]`），由 `jJ[0x479]` 决定。预热/补解密必须对准正确的槽。
5. **wasm 是字节码 VM**：`func 51`/`func 71` 是 `br_table` 解释器，恒等 = 密钥槽空；不要试图直接 patch wasm（强制 `global 9=2` 会破坏输出缓冲 → `out=0`）。
6. **`pushAccessUnit` 延迟推送**：VideoSample 累积到下一个 GOP 边界才推出，这是 FIX-PB「后续帧回写」能生效的前提。
7. **首帧 P/B 滞后 1 帧是良性异常**：浏览器 H.264 错误隐藏会掩盖，不导致可见花屏。

---

## 五、诊断体系与日志约定

### 5.1 日志位置（均在 `bin/Debug/net10.0-windows/win-x64/`）
- `cctv-debug.log` = WebView2 `postMessage`（CMGDEC1/2、FIX-PB、LOC-SPOOF、net 拦截、Hls 不支持等）。
- `cctv-proxy.log` = Go stdout（`[diag]` 注入、`SAPI GET`、`MEDIA GET`、`/open-token`、`SAPI 抓取失败`）。

### 5.2 关键诊断行
| 日志 | 含义 |
|------|------|
| `CMGDEC1#N t=<type> in/out same=Y/N` | 第 N 个 NALU 解密：type=5(IDR)/1(P/B)；`same=Y`=恒等失败 |
| `[LOC-SPOOF] steps=[...] verified=` | 导航伪装诊断；`proto-href:ok` 证密钥种子来源正确 |
| `[FIX-PB] 补解密成功 #N len= inplace=Y/N` | 第二帧补解密回写（v4 原地写回标志） |
| `[WARM] primed P/B slots` | IDR 预热 P/B 槽（v3，已证无效但保留无害） |
| `[DISP] cmd=InitPlayer ... loc=` | 派发器 InitPlayer 读到的 location（应为 yangshipin.cn） |
| `[diag] 种子URL#N 已注入 / WARN` | main.go 注入串命中情况 |
| `[非致命:mediaError/bufferSeekOverHole]` | hls.js 直播分段良性缓冲事件，非花屏 |

### 5.3 判读流程
1. 先看 `cctv-proxy.log` 是否有 `SAPI GET` / `MEDIA GET` 且 HTTP 200 → 网络层正常。
2. 看 `CMGDEC1#1`(IDR) 的 `same`：若 `Y` → 导航/种子问题（回看 `[DISP] loc=` 与 `[LOC-SPOOF]`）；若 `N` → IDR 解密成功。
3. 看 P/B 帧 `same`：若仅 #2 `Y`、其余 `N` → 良性单帧异常，无需处理。
4. 看是否有 `[JS] Hls不支持` → 多半是**注入串 JS 语法错误**导致整段 hls.cmg.js 失效（见 6.2）。

---

## 六、构建 / 部署流程（强制）

### 6.1 改 `main.go` 注入串后（强制）
```
cd d:/TV/CCTV/cctv-proxy
.\build.ps1
```
`build.ps1` 内部：**先 `verify_inject.cjs`（把全部反引号注入串应用到缓存 hls.cmg.js/cmg.worker.js，`vm.Script` 校验整文件语法，失败即中止）→ `go build` → `Copy-Item` 覆盖 `bin/Debug/net10.0-windows/win-x64/cctv-proxy.exe`**。
- **勿裸 `go build`**：注入串语法错误会让整段 hls.cmg.js 解析失败、全局 `Hls` 未定义 → 报「Hls不支持」，极易误判为 HTTP/2 回退。

### 6.2 语法校验教训（反复踩坑固化）
每次改注入字符串（cmgDecNew/cmgDecNew2/fetchGate/initBlock 等）后，**必须**走：① 提取到 `.js` → ② `node --check` + 括号深度扫描器确认 `depth=0` → ③ 才 `go build` + 覆盖。**绝不在未校验语法的情况下部署**。

### 6.3 缓存与复制
1. `go build` 产物 `d:/TV/CCTV/cctv-proxy/cctv-proxy.exe`；C# 从 `bin/Debug/net10.0-windows/win-x64/cctv-proxy.exe` 启动。每次改 `main.go` 必须 `Copy-Item` 覆盖 bin exe。
2. `sapi_cache/` 必须随 exe 复制到 bin 目录（`bin/.../sapi_cache/` 含 `assets_2025_wasm_hls.cmg.js` 与 `cmg.worker.js`）。注入是响应时应用，故改注入代码只需重编 + 覆盖 exe，缓存无需更新（除非上游更新才删缓存重抓）。
3. `player.html` 脚本 ver 被 `/player` 改写成时间戳强制重拉；`/sapi` 与 `/player` 响应加 `Cache-Control:no-store`。

### 6.4 改 C# 后
`dotnet build -c Debug`（EXIT=0），重启 CCTVPlayer。

---

## 七、常见问题与排错

| 现象 | 根因 | 处理 |
|------|------|------|
| `401` 空 body | 算法错 或 时效值过期 | 区分：auth 用 `su`/Ac，live body 用 `au`/Tc，`yspsdkinput` 用无盐 `ne`(localeCompare)；cKey/yspticket/token 须实时生成 |
| `20401` 获取直播信息失败 | `sig2` 用了 `authToken` | 改用 `sessionToken` 算 `sig2`，`yspplayertoken` 头仍用 `authToken` |
| `networkError` / `manifestLoadError` | CORS / TLS 指纹 | 媒体全走 `/media` 代理；CMG 脚本走 `/sapi` 同源 |
| `[JS] Hls不支持` | **注入串 JS 语法错误**导致整段 hls.cmg.js 失效 | `node --check` 校验注入串；`build.ps1` 已内置 |
| 全帧花屏（有声音无画面） | ★ 2026-09 更正：**不是**导航问题，而是**种子三要素**没对齐（导航官网只是"碰巧"把三要素一次凑齐了） | 依次检查：① `activeURL` 是否**完整 43 字符含域名**（不能是 `replace('yangshipin.cn','')` 后的 30 字符短串）且 `writable:true`；② `self.origin` 的 emval Proxy 是否生效；③ WEVAL(eval) hook 是否命中。见 §十 |
| **只坏 P/B 帧（t=1）、IDR（t=5）正常** | `self.origin` 经 emval 泄露（**不走 eval**，旧 WEVAL 的 `/location/` 正则漏拦了它） | 上 emval `origin` Proxy（§10.3） |
| 仅首帧 P/B 花（其余正常） | 密钥槽异步滞后 1 帧（**种子修对后基本消失**） | 先看 `same=N/Y` 比例；>1% 属种子问题而非"良性"，见 §4.8 更正 |
| `CMGPlayer.json` 404 | ★ 2026-09 更正：它**确实会被 fetch**（浏览器与 wasm2c 原生均已实证）。它是**算法开关表**（VER/RSA/SM2/CRC32/AES/MD5），**不是密钥**；但**缺失时 InitPlayer 会走 decoy 分支**（wasm2c 原生实测：不 fetch → `jsdecLive8` 恒等直通） | 本地直供一份（`__CMGPLAYER_JSON__`，225B）。不要因为它"看起来不像根因"就删掉对应路由 |
| 30s 后马赛克式花屏 | wasm 内部 ~750 帧计数器（**反篡改自检**，非许可证）无法从 JS 重置 | ★ 已解决：VMPATCH3 内存热修补（见 8.8）。⚠️ 扫描范围 `6684672~6698000` 与 wasm 版本绑定，上游更新（现 `V=1.2.1` / `CMG_BTime=Aug 13 2025`）后需重新确认 |
| 鸿蒙：切台后黑屏 + `memory access out of bounds` | `__SLIM_WRITE_EB__` 闭包捕获了**第一个**实例的 `HEAPU8/eb`；第二实例把 eb_prog 写进了前一个实例的堆 | slim 改为 `__SLIM_WRITE_EB__(HEAPU8,HEAPU32,ebPtr)` 接收参数，并删除 `__SLIM_DONE__` 防重（见 §11.4） |
| 鸿蒙：媒体卡片**没有台标** | ★ 2026-09 更正：Web 侧 `navigator.mediaSession.metadata` **从未生效**——日志 `artwork 已设置` 正常但系统媒体卡无台标 ⇒ **ArkWeb 不把 MediaSession artwork 桥接到系统 AVSession**。不是推送时机/尺寸/格式问题 | **唯一可用方案 = 原生手动 `createAVSession` + `setAVMetadata({mediaImage: PixelMap})`**（必须 catch `6600101`；见 §12.3） |
| 鸿蒙：手动 `createAVSession` 后媒体卡片**消失** | ★ 2026-09 更正：**不是**"手动 create 冲突"。真因是把 **`6600101`（Session 已存在，ArkWeb 可能已先创建）当致命错误**处理。正确处理 6600101 后，手动 create 是**台标的唯一可用方案**（用户实测"完美解决"） | 按 §12.3 实现：catch `6600101` 跳过 + 先注册监听再 `activate()` + 退出 `deactivate()`/`destroy()` |

---

## 八、第四战役：长期播放衰减与自愈方案（2026-07-16）

### 8.1 现象

密钥种子修复后，每个频道播放约 17-30s（~750 帧）开始出现**马赛克式花屏**（与未解密像素斑不同：马赛克=部分帧正确、部分帧错误交替，画面呈现块状模糊）。切换频道重建页面后恢复正常，再播 17-30s 又花屏——循环往复。

### 8.2 诊断与定界

扩展 CMG 诊断至 1200 帧 + 每 200 帧紧凑健康检查 `[CMG]`，确认规律：

| 指标 | 所有测试一致结论 |
|------|-----------------|
| 首次 `same=Y` | **总是第 #751 帧**（约 15-17s） |
| `ts` / `mt` 值 | 全程不变（`jJ['config'][0x291]` 仅 init 时赋值一次） |
| Y/N 分布 | 同一 TS 批次内 Y/N 交替，非全部 Y |
| FIX-PB 重试 | **全部失败**（`[FIX-PB-FAIL] 仍恒等`），证明 wasm 拒绝重解密 |

**根因定性**：wasm 内部有一个**不可从 JS 导出重置的 NALU 计数器**，累积到约 750 个 NALU 后开始选择性返回恒等（`same=Y`）。这与密钥种子/过期无关——是 wasm VM 内部状态机。

### 8.3 尝试的方案与结论

| 方案 | 原理 | 结果 | 结论 |
|------|------|------|------|
| **KEYROT** (v1) | 每 7s 更新 `mediaTagId`/`config[0x291]` 为 `Date.now()` + `UpdatePlayer` | 帧#1 全 Y（触发过早扰乱 init）；加守卫后仍全 Y | **破坏 wasm 内部状态**，方向错误 |
| **REKEY** (v2) | 每 14/8/5/3s 调 `_CMG_InitPlayer(原始ctx)` 重派生密钥 | 14s 时延长到 23s，但 5s/3s 无改善，首次 Y 仍 #751 | **不重置 NALU 计数器** |
| **UnInit+Init** | 先调 `_CMG_UnInitPlayer` 再调 `_CMG_InitPlayer` | 首次 Y 提前至 #367 | **UnInit 破坏上下文字段，更糟** |
| **FIX-PB 重试** | 检测到 same=Y 时存储帧，下一成功帧回写重解密 | 全部 `[FIX-PB-FAIL]` | **wasm 拒绝重解密已失效帧** |
| **CMD-SCAN** | 首次 same=Y 后尝试 40+ 种 dispatcher 命令字符串 | 无命令恢复解密 | **密钥状态不是简单命令可恢复** |

> ★ 核心困难：**解密 wasm 是 VMProtect 式的字节码虚拟机（`func 51`/`func 71` 用 `br_table` 做指令分发）。内部计数器在 wasm 线性内存中，无 JS 导出接口可重置。唯一有效重置手段 = 完整页面重载（`CoreWebView2.Navigate`），这恰好是「切换频道」的实现方式。

### 8.4 最终方案：C# 层自动重载（自愈）

**原理**：复刻用户切频道的行为，在花屏出现前自动重载页面。

**实现**（`MainWindow.xaml.cs`）：
```csharp
// 字段
int _cmgTotal, _cmgSameY;
DateTime _lastAutoReload = DateTime.MinValue;

// WebMessageReceived 中
if (obj?["log"] != null) {
    var m = obj["log"]!.ToString();
    Log($"[JS] {m}");
    CheckAutoReload(m);
}

void CheckAutoReload(string msg) {
    if (!msg.Contains("same=Y") && !msg.Contains("same=N")) return;
    _cmgTotal++;
    if (msg.Contains("same=Y")) _cmgSameY++;
    if (_cmgTotal < 80 || _cmgTotal % 20 != 0) return;
    var ratio = (double)_cmgSameY / _cmgTotal;
    if (_cmgTotal > 200 && ratio > 0.25 &&
        (DateTime.Now - _lastAutoReload).TotalSeconds > 25) {
        _lastAutoReload = DateTime.Now;
        _cmgTotal = 0; _cmgSameY = 0;
        Dispatcher.Invoke(() => PlayChannel(_autoReloadChName));
    }
}
```

**参数**：`same=Y` 比率 > 25%，200 帧后每 20 帧检查，冷却 25s。

**效果**：播放 30-40s 清晰 → 自动重载（2-3s 黑屏）→ 继续清晰 30-40s → 循环。

**缺陷**：重载有短暂黑屏（导航+YSDK 初始化耗时），约 2-3s。对长时间观看有间断感。

### 8.5 理论上的更优方案（待探索 → 已解决）

1. **双播放器轮换（消除黑屏）**：保持两个 WebView2，一个播放、一个后台加载，到衰减时间点切换前台。缺点：双倍内存/CPU、同步复杂。
2. **wasm 内存热修补**：★ **已实现！** 见 8.8 VMPATCH3。找到 wasm 线性内存中的 VM 程序区域，定时对比并还原所有变化字节，阻止计数器累积。
3. **完整 SDK 适配**：如果央视频官方有 H5 播放器 SDK（不同于当前抓取的 webpack 模块），可直接对接而非借用 wasm。

### 8.6 根本问题分析

我们面临的最大障碍不是「没找到密码」——密码（密钥种子）早在第三战役（`location.href` 修复）中就正确了。证据：
- 前 750 帧全部 `same=N`，`diffN` 数百到数千字节确实发生了变化
- 熵值 `ent_in ≠ ent_out`，证明输出已脱密

**真正的问题是**：CMG 的 wasm 解密是**逐 NALU 的有状态解密**，内部维护一个 NALU 计数器/会话状态。官方播放器（yangshipin.cn 原生页面）可能通过以下机制维持长期播放：
- 定期向服务器请求「license 更新」刷新 wasm 内部状态
- 使用不同的 wasm 导出组合（如 `_CMG_jsdecLive0~8` 按 NALU 索引轮换）
- 完整的 CMGPlayer SDK 做了我们未知的初始化步骤

我们当前架构「借用」了官方的 `hls.cmg.js` + `cmg.worker.js` 但运行在简化的 hls.js 环境中，缺少完整的会话管理闭环。

### 8.7 kvcollect 心跳的逆向与尝试

**动机**：用户抓包发现官网有 `aatc-api.yangshipin.cn/kvcollect` 每分钟 POST 一次，怀疑这是 wasm 会话的"许可证续签"机制。

**逆向结果**：

1. **请求端点**：`POST https://aatc-api.yangshipin.cn/kvcollect`（`Content-Type: application/json`）
2. **关键字段**（从 `chunk-vendors.86ef4b5a.js` 的 `hu(t,e,n,r)` 函数逆向）：
   - `BossId = "9" + t.BossId`（源中是 `9150`，加上前缀"9"得 `99150`）
   - `Pwd = 1999332929`（硬编码）
   - `ftime = bc()`（当前时间 `yyyy-MM-dd HH:mm:ss`）
   - `progid`/`viewid`/`livepid` = 频道 pid
   - `durl`/`url` = 完整 m3u8 URL
   - `fplayerver="189"`、`platform="5910204"`、`appver="1.1.11"`、`switch="fhd"`、`defn="fhd"`、`cmd=263`（`f>0?263:205`）、`nettype="4g"`
3. **签名算法**：
   ```
   signature = MD5(
     fields 按 Ordinal 字母序拼接(k=v 用 & 分隔, 排除 signature 本身)
     + AuthSalt
   )
   // AuthSalt = "n@7QKk%YeSjfw%22" (生产环境, 与 /auth 共用)
   ```
4. **C# 实现**：`CctvApiClient.ComputeKvCollectSignature()` + `SendKvCollectAsync()`，每 60s 调一次。

**测试结论**：

| 指标 | 数值 |
|------|------|
| `[KVC] 心跳 OK` 出现次数 | 2 次（成功） |
| 第一次 same=Y 帧号 | **#752**（与无 kvcollect 完全一致） |
| 30s 衰减 | **仍然发生** |

**结论**：kvcollect 只是**遥测追踪**（记录用户在观看），不是 wasm 的"许可证续签"机制。央视频的 30s 衰减是 wasm VM 内部状态机的硬限制，外部 HTTP 调用无法重置。

**价值**：
- 完全破解了央视频一个生产接口的完整格式
- 相同的 MD5+AuthSalt 算法模式可用于其他央视频接口
- 如果未来发现真正的 license 续签接口（如 `/license/renew`），可用相同方法快速接入

### 8.8 ★ VMPATCH3：wasm 内存热修补（终极解决方案）

**这是本项目最重要的技术突破。** 经过 7 种方案的探索（KEYROT/REKEY/UnInit+Init/FIX-PB/CMD-SCAN/AUTO-RELOAD/DISP-REINIT），最终发现：wasm VM 的 750 帧计数器虽然藏在 VM 栈帧局部变量中无法从 JS 直接访问，但**可以周期性完整还原 wasm 内存到初始状态，阻止计数器累积**。

#### 8.8.1 原理

1. **理解 wasm 线性内存**：CMG wasm 的 `memory` 是 JS 可读写的 `ArrayBuffer`。VM 解释器(`func[51]`)在执行字节码时将计数器写入线性内存的**动态分配区域**（从 context 指针 `6687992` ～ `6698000` 的 ~96 个 4KB 非零块）。

2. **计数器累积模式**：每次 `func[99]`（`_CMG_jsdecLive8`）调用 `func[51]` 时，VM 解释器在 3 个固定区段（`@6689120`、`@6693216`、`@6697312`）修改总计 ~9600 字节。

3. **热修补策略**：
   - **T+6s**（InitPlayer 完成后）：snapshot wasm 内存中所有非零 4KB 块的初始值（~96 块 × 4096B ≈ 384KB）
   - **每 2s**：对比当前值 vs 初始值，将所有变化字节**原地写回初始值**
   - **效果**：计数器永远无法累积到 750 帧阈值 → 永不衰减

#### 8.8.2 实现（`main.go` earlyWrap 注入）

```javascript
// T+5s: snapshot 初始值
var __vmSnaps=[], __vmBases=[];
setTimeout(function(){
  var mod=window.CNTVH5PlayerModule;
  var u8=mod&&mod.HEAPU8||(mod&&mod.asm&&mod.asm.memory&&new Uint8Array(mod.asm.memory.buffer));
  if(!u8)return;
  // 扫描 6.3MB~6.8MB 区域的所有非零 4KB 块
  for(var page=6684672; page<6698000; page+=4096){
    var hasData=false;
    for(var off=0;off<4096;off++){if(u8[page+off]!==0){hasData=true;break;}}
    if(hasData){
      __vmBases.push(page);
      __vmSnaps.push(new Uint8Array(u8.slice(page,page+4096)));
    }
  }
  if(window.chrome&&window.chrome.webview)
    window.chrome.webview.postMessage({log:'[VMPATCH3] snapshot '+
      __vmBases.length+' blocks ('+__vmBases[0]+'..'+__vmBases[__vmBases.length-1]+')'});
},6000);

// 每 2s: 对比并原地写回
setInterval(function(){
  var mod=window.CNTVH5PlayerModule;
  var u8=mod&&mod.HEAPU8||(mod&&mod.asm&&mod.asm.memory&&new Uint8Array(mod.asm.memory.buffer));
  if(!u8||!__vmBases.length)return;
  var totalDiff=0;
  for(var bi=0;bi<__vmBases.length;bi++){
    var base=__vmBases[bi], snap=__vmSnaps[bi];
    for(var off=0;off<4096;off++){
      if(u8[base+off]!==snap[off]){
        u8[base+off]=snap[off];
        totalDiff++;
      }
    }
  }
  if(totalDiff&&window.chrome&&window.chrome.webview)
    window.chrome.webview.postMessage({log:'[VMPATCH3-FIX] '+totalDiff+' bytes reset'});
},2000);
```

#### 8.8.3 测试结果

| 指标 | 数值 |
|------|------|
| 首次 `same=Y` | 仅帧 #2（良性，InitPlayer 异步滞后 1 帧） |
| 30s 后 `same=Y` | **0 帧** |
| 40s 后 `same=Y` | **0 帧** |
| VMPATCH3-FIX 触发 | 每次 ~9600 字节还原（3 块：6689120/6693216/6697312） |
| 自动重载 | **0 次（完全不需要）** |
| 黑屏 | **0 次** |
| 花屏 | **0 帧（除 #2 不可见良性异常）** |

**结论：纯净无间断播放，彻底解决 30s 衰减问题。**

#### 8.8.4 与前方案的对比

| 方案 | 花屏 | 黑屏 | 复杂度 | 体验 |
|------|------|------|--------|------|
| 无修复 | 17s 后持续 | 无 | — | ❌ |
| KEYROT | 更早发生 | 无 | 高 | ❌ |
| REKEY (InitPlayer) | 17s 后持续 | 无 | 中 | ❌ |
| AUTO-RELOAD | 2-3s 后恢复 | **2-3s 间断** | 中 | ⚠️ |
| **VMPATCH3** | **0** | **0** | 低 | ✅ **完美** |

#### 8.8.5 为什么它有效而其他方案无效

- **KEYROT/REKEY**：调 `InitPlayer` 无法重置 VM 栈帧中的局部计数器（InitPlayer 只初始化密钥槽，不解构 VM 栈）
- **AUTO-RELOAD**：有效但重建整个页面（5-8s 开销），不是"修补"而是"重建"
- **VMPATCH3**：直接操作 wasm 线性内存，阻止计数器累积。无需理解 VM 字节码语义，只需"定期还原到初始状态"

#### 8.8.6 注意事项

1. **Snapshot 时机**：必须在 InitPlayer 完成**之后**（`setTimeout 6000ms`），否则快照的是未初始化的零值区域
2. **性能**：每 2s 扫描 ~384KB 内存，JS 耗时 < 5ms，不影响帧率
3. **兼容性**：依赖 `HEAPU8`（Emscripten 标准），所有 wasm 运行环境均可用
4. **局限性**：如果央视频更新 wasm 二进制改变内存布局，需重新确认 snapshot 范围（但 `6684672~6698000` 是 wasm 全局数据段，稳定性高）

---

## 九、为什么要重开解密战线（承上启下）

到 V5.0 结束（VMPATCH3），项目其实**已经能用**了。但 2026-08 又把解密这条线重新打开，原因是旧结论带来了三个**绕不过去的工程代价**：

1. **必须真实导航官网** —— 合规/审核风险，而且官网 DOM 是移动靶。
2. **`cmg.worker.js` 1.3MB** —— 每次冷启动都要解析 110 万字符的十进制数组字面量，冷启动慢。
3. **鸿蒙端要落地** —— 而鸿蒙**根本用不了**「导航官网 + `WebResourceRequested` 拦截」这一套（ArkWeb 没有等价机制）。

于是从 2026-08-31 起，在 `d:/TV/CCTV/rev/` 建了 **Node 离线逆向实验室**（`exp1_load.cjs` / `exp3_hls.cjs` / `exp4_proof.cjs` / `exp5_init.cjs`），**不受既有文档与记忆约束**、以实证为准重新逆向。

结果：**推翻了多条"铁证级"结论**（见 §〇 的推翻表），并顺带打开了三条新战线——**瘦身（§十一）/ 鸿蒙（§十二）/ 原生解密可行性（§十三）**。

> ### 📌 方法论教训（值得单独记住）
>
> V5.0 之所以会得出「`location.href` 是唯一真因」这个错误结论，是因为——
> **导航官网这一个操作，恰好同时把 `location` / `activeURL` / `origin` 三个变量都改对了。**
> 一个动作修好了三个变量，于是被误判成"只有一个变量"。
>
> **教训：当"A 方案把问题修好了"时，不要急着下结论说"缺的就是 A"。先问一句——A 是不是顺带把 B 和 C 也改对了？**
> 后来定位 `self.origin`（§10.3）正是靠这个问题意识：**只坏 P/B 帧、IDR 正常**这个"奇怪"的症状，说明还有第二个变量没被 A 覆盖到。

---

## 十、第六战役：种子真相重审 → 不再导航官网（2026-08-31 ~ 09-01）

> 本章**推翻 §4.4 / §4.5**。在 `d:/TV/CCTV/rev/` 建立 Node 离线逆向实验室后重新实证所得。

### 10.1 为什么要重审
V5.0 的结论「`location.href` 是 C++ 绑定 → 只能真实导航官网」能work，但代价很大：①必须让 WebView 真的访问官网（**合规/审核风险**）；②官网页面 DOM 随时可能变，脆弱；③**鸿蒙端根本用不了同样的导航手段**。所以必须搞清楚"到底是谁在读 location"。

### 10.2 事实一：wasm 取 location 的唯一出口是 `eval()`，而 `eval` 可 hook
- `cmg.wat` 中 `call 21`（= import `env.y` = `_emscripten_asm_const_ii`）**全模块仅 1 处**，位于 `func[51]`（VM 解释器）第 2999 行。
- `ASM_CONSTS[0]` 即 `theAnswer`：`eval(name)`；数据段里只有 `self.location.host` / `href` / `protocol` 三个表达式。
- **`eval` 是普通全局函数，可以 hook** → **WEVAL hook**：拦截含 `location` 的 eval 表达式，返回 `yangshipin.cn`。
- 实测确认：`InitPlayer` 期间**只调用一次** `self.location.host`。

### 10.3 事实二 + 三：`activeURL` 才是真种子，`self.origin` 是第二个泄露点
- `moduleDecData(jC=module, jD=mediaTagId, jE=nalu, jF='live'|'vod')` 每次解密都：
  `_jsmalloc(len+2048)` → 拷 nalu → **把 `self.activeURL` 的 charCodes 追加到 nalu 之后** → 拷 mediaTagId → `StaticCallModuleLiveAPI` → 取回 `slice(jN, jN+jO)` → `_jsfree`。
- 调用签名（4 参数，已实证）：`_CMG_jsdecLive8(tagIdPtr, naluPtr, naluLen, urlLen)`，返回输入长度、**原地写回**。内存布局 `[nalu][activeURL charCodes][mediaTagId charCodes]`。
- **第二个泄露点**：官方 `moduleActive` 的 INITPLAYER 分支**第一个取值就是 `self.origin`**（优先于 `location.href`）。路径：`wasm VM → import __emval_get_global('origin') → globalThis.origin`（真实值）。它**不走 eval**，所以旧 WEVAL hook 的 `/location/` 正则**漏拦**了它。
- 修复（`rev/gen_slim.cjs`）：把 `emval_get_global()` 的返回值换成 **Proxy** —— 拦 `origin` → `https://yangshipin.cn`、`location` → fake 对象，其余全部转发真 window（函数 bind 原 receiver）。
- **症状指纹（非常好用）：只坏 P/B 帧（t=1），IDR（t=5）正常。**

### 10.4 A/B 实测对照（等价性证明）

| 轮次 | 导航 | same=N | same=Y | FIX-PB 失败 |
|---|---|---|---|---|
| 修复前 | 官网 | 1199 | **1** | 0 |
| 修复前 | 本地 `127.0.0.1` | 1206 | **1194**（几乎全是 t=1 的 P 帧） | 9378 |
| **修复后** | **本地 `127.0.0.1`** | **6013** | **9** | 4 |

**结论**：修复后前 1200 帧的 `same=Y` = 1，与导航官网轮**完全相同**；残余 9 帧是因为本地轮采样更久（6022 帧 / 2 分钟+），且失败帧同属子流 `419a28d8...`（两种导航共有，非本地引入）。用户确认**画面不花屏**。

### 10.5 正确的最小种子配方（可复用，取代"真实导航"）
1. 预置 `self.activeURL = 'https://yangshipin.cn/tv/home?pid=<pid>'` —— **完整 43 字符、含域名**，`writable:true`。
   - ⚠️ **千万别按官方原版逻辑去 `replace('yangshipin.cn','')`**：`DISP-INIT-BLOCK` 注入已经**跳过了官方那句赋值**，wasm 用什么种子**全看你预置什么**。用 replace 后的 30 字符短串 → 全帧花屏（**这个坑已实打实踩过一次**）。
2. WEVAL hook `window.eval`，拦 `self.location.host` / `href` / `protocol`。
3. emval `origin` Proxy（否则只坏 P/B 帧）。
4. `CMGPlayer.json` 本地直供（225B）。

### 10.6 ★ 顺带推翻：「纯 Node 解密不通」是伪命题
- `ab_test.cjs` 实证：**官方 `fG` 在 Node 解密 5/5 成功**（同 wasm / 同 `seg0.ts`）。
- 成败差异 = **解密时的 `activeURL`（`jL`）**：官方 `moduleActive` INIT 会用 `self.origin||location.href` **覆盖** activeURL（Node 里 = 22 字符 localhost）。`ab_test` 靠 `CmgDec.ensureInit()` 事后改回 43 字符 SEED 才成功；`compare_fg`（22 字符）/ `node_play`（未赋值 → `jL=0`）恒等。
- **但仍有未分离变量**（`final_test` 在 `jL=43` 时也恒等）⇒ **从未做过干净对照**，"依赖浏览器环境"只是残余解释，**不要再当定论引用**。
- 附：`jsdecLive8` 是**状态机变换**（对已解密数据二次调用仍会改变），**不是 XOR**。⇒ **"diff>0" 不等于"解对了"**，判断正确性必须用**与官方输出逐字节比对**。
- Node 陷阱：`noInitialRun` 必须省略（需 `callMain` 执行）；fetch 旁路字段须对齐官方 onload（`n+12` dataPtr / `n+16` setu64 numBytes / `n+40` readyState / `n+42` status）。

---

## 十一、第七战役：源文件瘦身 slim（2026-09-01）

### 11.1 体积构成实测（`cmg.worker.js` 共 1,301,299 字节）

| 组成 | 体积 | 占比 |
|---|---|---|
| `HEAPU8.set([...])` VM 字节码数组（**十进制字面量**） | 1,103,969 字符 | **85%** |
| wasm base64 | 86,192 字符（64,644 字节） | 6.6% |
| Emscripten 胶水 + 其他 | ~111 KB | 8.5% |

对应二进制 `eb_prog.bin` = 378,592 字节。十进制数组 ≈ 2.9 字符/字节，base64 = 1.33 字符/字节。

### 11.2 交付基线 v1 = slim 外链（不可回退）
- `cmg.slim.js` 186KB + `eb_prog.bin` 378KB + `reloc_table.bin` 40KB ≈ **604KB**，替代 `cmg.worker.js`（1.30MB）。
- **官方 `hls.cmg.js`（704KB）保留**——它是解密的**调用方**，替换它等于要重写解密前置逻辑（见 11.3）。
- 相比原始 2.0MB（worker + hls.cmg.js），**省 ~70%**；运行时还免去解析 110 万字符的十进制数组字面量。
- 产物在 `rev/dist/`。

### 11.3 ★ V2 瘦身失败（重要教训，勿重复投入）
- **目标**：标准 hls.js（413KB）+ 自写 `cmgdec.js`（7.8KB）替换官方 `hls.cmg.js`（704KB）。
- **结果**：桌面与真机均 **diffBytes=0 / 绿屏**，**仅 CCTV-6 能播**——CCTV-6（pid=600108442，`mobilelive-play` 源）是 `avc1.4d4028`（Main profile）且**流不加密**；其他频道 `avc1.640129`（High）需 CMG 解密 → 绿屏。
- **关键**：自写桥与官方在 **Node 中都能"解密"**（`ab_test` diff>0 5/5），但在**浏览器里不行** → **官方 `hls.cmg.js` 内部存在未识别的解密前置逻辑**。
- **决策：已回滚 v1，V2 暂缓/放弃。** 继续深挖成本高、收益低（仅省 704KB）。
- **教训**：自写解密链路**必须先在桌面 WebView2 验证（`same=N`）再上鸿蒙**，否则真机绿屏时无从定位。

### 11.4 多实例陷阱（鸿蒙切台黑屏）
- **症状**：首台能播；切台 `Uncaught (in promise) RuntimeError: memory access out of bounds`，新台"缓冲中"黑屏。
- **根因**：`__SLIM_WRITE_EB__` 定义在 `globalThis`，**闭包捕获了第一个实例的 `HEAPU8/HEAPU32/eb`**；切台时 ArkTS `[PREFETCH]` 建第二实例 → 其 `initRuntime` 调同一全局函数 → eb_prog 写进**第一个实例的堆** → 第二实例内存里没有 eb_prog → 越界。`__SLIM_DONE__` 防重还让第二实例**直接跳过装载**。
- **修复**：改为 `__SLIM_WRITE_EB__ = function(H8, H32, ebPtr){...}` 接收参数，`initRuntime` 注入处传本实例堆；**删除 `__SLIM_DONE__`**。

### 11.5 eb_prog 提取与重定位（自洽验证）
- eb_prog 由 **37 段 `HEAPU8.set([...], eb+N)`** 拼装；写完后运行时重定位：`for(e=0;e<A.length;e++) HEAPU32[eb+A[e]>>2] += eb;`（A 表 10,240 项，范围 [800, 369532]）。
- 静态提取（未重定位）+ 重定位 == 官方运行时内存，**逐字节吻合**（自洽验证）。

**踩坑（勿重犯）：**
1. 数组元素/偏移含**科学计数法**（`16e3`、`36e4`、`256e3`），必须用 `Number()` 而非 `parseInt`（后者会在 `e` 处截断成 `256`）。
2. `writeUInt32LE(v, i)` 第二参是**字节偏移**（必须 `i*4`），写错会逐字节重叠覆盖 → 重定位全失效。
3. 括号配平扫描 `HEAPU8.set(` 时 **depth 初值必须为 1**（已消费左括号），从 0 起算会提前结束。
4. **`__ATPRERUN__.push` / `__ATINIT__.unshift` 挂载均失效**（回调从未被消费）——必须**直接改 `initRuntime()` 函数体首部**注入。
5. **替换顺序**：`initRuntime` 定义在偏移 9305，早于大块起点 99754 → **必须先做大块 substring 替换，再改 initRuntime**，否则偏移全部失效。

### 11.6 解密槽位速查（Proxy 实测）
功能名索引 → 导出：**8 = `MpegAudio` → `_CMG_jsdecLive8` / `_CMG_jsdecVOD8`**；7 = H264NalSet；6 = H265NalData；5 = AVS1AudioKey；4 = HEVC2AAC；3 = HASHMap；2 = BASE64Dec；1 = MediaSession；0 = Mp4fragment。

---

## 十二、第八战役：鸿蒙落地（CctvPoC）与媒体卡片台标

### 12.1 方案 A = ArkWeb + slim（同 WebView2 内核）★ 已落地
- 真机正常换台。**改用 ArktsProxy（纯 ArkTS 本地 HTTP 服务 `127.0.0.1:18888`）替代 Go 子进程**——**鸿蒙手机不支持启动 native 子进程（错误 801）**，这是与桌面架构最大的差异。
- **★★ 部署陷阱（务必遵守）**：`CctvPoC/entry/src/main/ets/pages/Index.ets` 的 `PLAYER_DEPLOY_VER` —— **每次修改 `rawfile/web/player.html` 必须 +1**。`player.html` 部署时被注入 WASM 生成 `player_boot.html` 并缓存，版本号不变则**改动永不生效**。
  - 判据：日志 `[runInit] player_boot.html 已读取` 后标 `(首次部署)` = 真重新部署；标 `(缓存命中)` = 用的是旧内容。

### 12.2 ★★ `enableNativeMediaPlayer` 与本项目解密架构**不兼容**（重要架构结论）
- 方案 A 的解密链路：`hls.cmg.js` 在 JS 里解出 NALU → `cmg.wasm` 解密 → 解密数据**只能经 MSE `sourceBuffer.appendBuffer()`** 送进解码器，此时 `video.src` 是 `blob:`/MediaSource（**没有真实 URL**）。
- 而 `enableNativeMediaPlayer` 的接管机制是：ArkWeb 把 `<video>` 的 `src`/`mediaInfo` 交给原生 AVPlayer 去拉流——**MSE 的数据根本不经过 `src`**。
- ⇒ 接管后 AVPlayer 播的是**原始未解密的 HLS** → 花屏/绿屏（与 §11.3 V2 失败"仅 CCTV-6 不加密能播"**同源**）。
- **二选一**：要解密 → 必须 MSE → 不能接管 → 拿不到原生解码性能；要接管 → 只能播不加密频道。**"Web 侧解密 + 原生解码"这个切分点上，数据跨不过去。**

### 12.3 ★★ 媒体卡片台标：唯一可用方案 = **手动 `createAVSession`**（2026-09-03 用户实测，**已推翻此前全部结论**）

> ⚠️ 本节**推翻**此前"台标真凶=推送时机 / 绝不手动 createAVSession"的结论。用户实测：**在不手动创建 AVSession 的前提下**，2026-09 做的大量修改（首帧补设、per-session 标志、CCTV-6 原生接管等）**全部无效**，已全部回退。

**先排除的干扰项**（保留了诊断价值）：
- `sizes` 写死 / dataURL 双前缀 / 图标缺失（仅 `bjcity` 缺）/ 图片格式 —— **全排除**，不是原因。
- **Web 侧 `navigator.mediaSession.metadata` 已正确设置**（真机日志 `[MEDIA-METADATA] artwork 已设置 144x72`，出现在 `[START]` 阶段、早于 m3u8 拉取）——**但系统媒体卡始终不显示台标**。

**★ 决定性结论**：`artwork 已设置` 正常 **≠** 台标出现。**ArkWeb 根本不会把 `navigator.mediaSession.metadata` 的 artwork 桥接到系统 AVSession**（该设备的 ArkWeb 版本行为如此）。再调"推送时机 / 尺寸 / 格式"都是无用功。

**★ 唯一可用方案（用户实测"完美解决"）**：**原生层手动 `createAVSession` + `setAVMetadata({ mediaImage: PixelMap })`**。关键实现要点（参考 `backup_CctvPoC_20260830_clean`，缺一不可）：
1. `avSession.createAVSession(ctx, 'CCTVPlayer', 'video')`；
2. **必须 catch `6600101`（Session 已存在）并跳过**——ArkWeb 可能已先创建，**这不是致命错误**。⚠️ 早年"媒体卡片消失（三次复现）"的真因就是**把 `6600101` 当致命错误处理**，**不是**"手动 create 本身会冲突"；
3. **先注册 `play`/`pause` 监听，再 `activate()`**；
4. 初始 `setAVPlaybackState(PAUSE)`（避免无音频流时系统拒绝显示），真正播放时改 `PLAY`；
5. 台标：`setAVMetadata({ assetId, title, artist, mediaImage: pixelMap, duration: 0 })`，`pixelMap` 由 base64 dataURL 经 `image.createImageSource` 解码得到；
6. 退出时 `deactivate()` + `destroy()` + 停用 AudioSession；
7. `initAVSession()` 与代理/页面启动**并行**执行（冷启动优化）。

**诊断**：grep `[MEDIA-METADATA]`（Web 侧）与 `[avsession] 媒体元数据已更新`（原生侧）。Web 侧出现 `artwork 已设置` 但无原生侧日志 = 手动 AVSession 没生效或没走原生路径。

### 12.4 ★ 概念澄清：`AVSession` ≠ `AudioSession`（"音频独占"担心的根源）

| | **AVSession**（AVSessionKit） | **AudioSession**（AudioKit `AudioSessionManager`） |
|---|---|---|
| 作用 | 媒体会话：播控中心 / 媒体卡片的**展示**（标题、台标、播放/暂停按钮） | 音频会话：决定**音频并发策略**（是否打断其他应用的声音） |
| 是否参与音频焦点 | **完全不参与** | **是**（`CONCURRENCY_MIX_WITH_OTHERS` / `CONCURRENCY_PAUSE_OTHERS`） |
| 手动创建的影响 | 只影响"有没有媒体卡 / 台标" | 只影响"混音还是独占" |

⇒ **手动 `createAVSession` 对"音频独占"零影响**，两者可独立配置：
- **要台标** → 手动 `createAVSession` + `setAVMetadata`；
- **要音频合规** → 只调 `AudioSessionManager` 的并发模式。

### 12.5 音频合规（AudioSession，与 AVSession 无关）
- Web 组件：`.mediaOptions({ resumeInterval:-1, audioExclusive:false, audioSessionType:10 })`（**两版代码一致**，`audioExclusive` 均为 false）。
- **当前（已回退）代码**：恒定 `CONCURRENCY_MIX_WITH_OTHERS`（最保守）。
- **08-30 备份（台标可用的那版）**：**动态**策略 —— 静音(`muted=true`) → `MIX`（不打断其他音频）；解除静音 → `PAUSE_OTHERS`（暂停其他音频）；退出 `aboutToDisappear` → `deactivateAudioSession()` 释放焦点。
- **上架风险评估**：
  - `PAUSE_OTHERS` 只在**有声播放**时生效，这是视频 App 的**标准预期行为**（与 YouTube / 央视频一致），不是滥用式"音频独占"；
  - 静音时主动 `MIX` 让出、退出即释放焦点 —— 合规性充分；
  - **若仍想绝对保守**：只恢复 AVSession 部分，AudioSession 保留**恒定 MIX** 即可，两者互不影响 → **台标解决 + 音频行为完全不变 + 上架风险最低**。

### 12.6 ★ 原生接管（AVPlayer）为何在 CCTV-6 上仍失败（2026-09-03 实测）
用 **CCTV-6（不加密）** 做"原生 AVPlayer 接管 + 自建 AVSession + 台标 PixelMap"的最小验证时，实测到：桥**确实**触发（`接管 cctv6`）、AVPlayer 也确实去拉了 m3u8，但 `state=initialized` 后**约 90ms 就被 `release()`**（从未到 `prepared`/`playing`），最终退回页面 hls.js 的 MSE 兜底（有声画、**无台标**）。
- **根因**：页面 `<video src=HLS .m3u8>` 让 ArkWeb **原生去加载 HLS → 元素 `error(no supported source)` → ArkWeb 随即 `release()` 接管桥**。
- **关键否定**：App 侧"在 `initialized` 时提前 `handleStatusChanged(PLAYING)`"**没能阻止释放**——释放是**元素报错**驱动的，与播放状态上报无关。
- **正确修法（页面侧）**：绝不让元素原生加载 HLS —— `nv.autoplay=false; nv.preload='none';` 且**不调用 `v.play()`**；`v.src=HLS` 仍会触发接管查询（`mediaInfo` 拿到真实 URL），播放交给应用侧 AVPlayer。
- ⚠️ 注意这与 §12.2 并不矛盾：**CCTV-6 不加密**，所以接管后播原始流也不会花屏；加密频道则因 §12.2 的原因**根本不能走接管**。

---

## 十三、第九战役：方案 B（wasm2c 原生解密）可行性判定（2026-09-02）

### 13.1 结论先行
- **解密核心已证实可以脱离浏览器正确工作。** 此前"方案 B 死刑 / 被否定"是 **harness bug 造成的假阴性**，已证伪，**不要再引用**。
- **但方案 B 整体仍冻结**（不投入鸿蒙 NDK）。瓶颈**不在解密**，而在 **AVPlayer 集成侧**。

### 13.2 决定性实验（run_out27）
- **假阴性根因**：`env.c` 的 `w2c_env_G(emval_as)` 对 `std::string` 错误地返回了 **emval 句柄 #8**，而不是 **wire 指针**（`{u32 len; char data[]}` 缓冲地址）。wasm 拿这个返回值去读 `self.location.host` 做域名校验（`host === "yangshipin.cn"`）：拿到 `#8` 当地址 → 读垃圾 → **域名校验失败** → `InitPlayer` 走 **decoy 分支**（不 fetch `CMGPlayer.json`、`jsdecLive8` 恒等直通）。
- **修复**：值类型（`std::string`/`bool`/`num`）返回 wire 指针，对象/未定义类型返回句柄。
- **结果**：`InitPlayer` 正常 `fetch CMGPlayer.json`（`fetch=1`）；**6/6 帧与 Node 官方 `fG` 输出逐字节一致**（自变化 2390/1204/400/384/423/1268，与 Node 差异 = **0**，refDiff 完全吻合）；import 计数对齐（Node `C:3 F:8 w:3 v:1 e:17 f:17 g:1`）。

### 13.3 剩余 blockers（都在 AVPlayer 侧，与解密无关）
1. **AVPlayer demux 不可插桩** → HLS/TS → PES → NALU → 解密 → 重喂解码器，**整条链路要自研**（方案 A 由 hls.js + 官方 `hls.cmg.js` **免费**提供）。
2. **解密输出非定长**（如 `in=32198 → out=32197`、`30874 → 30872`）→ 必须改写 NALU 长度字段并重封装。
3. **`InitPlayer` 是字节码 VM、递归极深**：Node 默认栈直接溢出，`--stack-size=200000` 跑 30s 仍未结束（anti-tamper）。纯 C 必须处理好线程/栈模型。
4. **anti-tamper 在 native 没有 VMPATCH3 的对应层**。

### 13.4 ★ 可行骨架（若将来要投入）：`OH_AVDataSource`
- 鸿蒙 **API 20（鸿蒙 6.0）起**，AVCodec Kit 提供 `OH_AVDataSource` 自定义数据源：实现 `readAt` 回调，把**已解密的内存数据**返回给 `AVDemuxer` → `AVCodec` → 渲染。
- **这直接破局"AVPlayer 黑盒不可插桩"**——数据源在你手里，demuxer 按 offset 从你这读。
- 流程：下载 ts → 解析出 NALU → 调 `.so`(wasm2c) 逐 NALU 解密 → 重封装成合法 TS（含 PTS、修正非定长 NALU）→ `readAt` 返回 → `AVDemuxer` → `AVCodec`。
- 前提/坑：①须**鸿蒙 6.0(API20) 以上**（注意：**`ArkWeb API 24 ≠ 系统 API 版本`**，须另查设备/SDK）；②`readAt` 是扁平字节流，须在内存里备好"已解密 + 已重封装 TS"完整片段供随机读；③HLS 多片段 + 播放列表要自管（自研 mini-HLS 客户端，处理片段缝合 + PTS 连续性 + discontinuity）。
- **收益**：解密核心（`.so`/wasm2c）已证零风险，剩余成本收敛为「TS 解析/重封装 + HLS 播放列表自管」，方案 B 从"难接"变成"可落地"。

### 13.5 关于「版本漂移 / 脆弱性」（用户指正，已采纳）
两方案**持平**，并非方案 B 独有劣势：方案 A 同样要重新抓 slim 包 + 重跑 `verify_inject` 注入串 + 重新上架。差异仅在「改 C 重编译」vs「改注入串重打包」，**都需要重新提交审核**。域名欺骗的脆弱性同理（方案 A 的 WEVAL / eval hook 也是逆向出来的）。
**真正的差异只有一条：AVPlayer 的 demux / NALU 集成成本**——方案 A 由 hls.js 免费提供，方案 B 必须自研。

### 13.6 决策
解密可行已证；是否投入方案 B 取决于「demux 自研成本 vs WebView 体验差距」。当前方案 A（ArkWeb）已落地，且三大动机（**台标 / 冷启动 / 音频**）**在方案 A 内部均可解决** → **维持方案 A 为交付基线**。

---

## 十四、总结

1. **参数体系**：用 `Wasmtime` 加载 `keygen_bg.wasm` 模拟导入函数，生成 `sig2`；`/auth` 拿 `authToken`（网关层）；`/web/open/token` 拿 `sessionToken`（算 `sig2` 的真正密钥）；`cKey`（纯 JS）、`yspticket`（`RJq7sO71JF.wasm`）均在 WebView2 内动态生成；`seqid` 用本地持久计数器递增。
2. **网络层**：媒体（m3u8/TS/key）全部经本地 Go 代理 `/media`（utls Chrome 指纹），CMG 脚本经 `/sapi` 同源加载，彻底规避 CORS / PNA / CDN TLS 指纹。
3. **★ 视频解密（2026-09 更正）**：CMG wasm 逐 NALU 解密。**必须逐 NALU**（每次都是完整独立的往返，漏一个即花屏），但**只需解 type 1/5**（SPS/PPS/SEI/AUD 本就明文），当前已是最小集，**无进一步优化空间**。种子三要素：
   - ① `self.activeURL` 预置**完整 43 字符含域名**，`writable:true`；
   - ② WEVAL hook `window.eval`，拦 `self.location.host` / `href` / `protocol`；
   - ③ emval **`origin` Proxy**，拦 `__emval_get_global('origin')`（漏这条 = **只坏 P/B 帧、IDR 正常**）。
   **不再需要真实导航官网**（见 §十）。
4. **★ 长期纯净播放（VMPATCH3）**：wasm 内存热修补——InitPlayer 完成后 snapshot 初始内存，每 2s 对比并原地写回所有变化字节。计数器永不到 ~750 帧阈值 → **无花屏、无黑屏、无重载**。⚠️ 扫描范围与 wasm 版本绑定，上游更新后需重新确认。
5. **★ 源文件瘦身（slim）**：`cmg.worker.js` 1.3MB → `cmg.slim.js` 186KB + `eb_prog.bin` 378KB + `reloc_table.bin` 40KB ≈ **604KB**。**官方 `hls.cmg.js`（704KB）必须保留**——替换它的 V2 方案已实证失败（见 §11.3）。
6. **★ 鸿蒙端（CctvPoC）**：ArkWeb + slim 已落地，真机换台正常；用 **ArktsProxy（纯 ArkTS 本地服务）**替代 Go 子进程（手机不支持 native 子进程）。台标走 `navigator.mediaSession.metadata`，**绝不手动 `createAVSession`**（见 §十二）。
7. **kvcollect 遥测**：完整逆向签名算法（MD5+AuthSalt），C# 每 60s 发送心跳，维持遥测活性。
8. **整体无需加载官网页面**，体验与原生播放器**完全一致**（无任何间断）。

**战役总结**：

| 战役 | 问题 | 方案 | 状态 |
|------|------|------|------|
| 第一战役 | 参数/鉴权/网络 | Wasmtime sig2 + Go 代理 | ✅ |
| 第二战役 | 视频完全不解密（全帧花屏） | ~~C# 导航 yangshipin.cn~~ → **种子三要素**（§十） | ✅（**结论已更正**） |
| 第三战役 | 第二帧异步滞后（单帧异常） | FIX-PB 原地写回 + WARM 预热 | ⚠️（**已被 §4.8 更正取代**：实为种子没修对的**症状**，种子修对后 `same=Y` 从 50% 降到 0.15%） |
| 第四战役 | 30s 后花屏 | AUTO-RELOAD（临时） | ⚠️（有黑屏，已被第五战役取代） |
| **第五战役** | **30s 后花屏（终极）** | **VMPATCH3 内存热修补** | ✅ **完美** |
| **第六战役** | **必须导航官网** | **eval hook + activeURL + emval origin Proxy** | ✅ **已推翻旧结论** |
| **第七战役** | **源文件 1.3MB 臃肿** | **slim 外链（604KB）** | ✅（V2 再瘦身 **失败已放弃**） |
| **第八战役** | **鸿蒙落地 + 媒体卡台标** | **ArkWeb + slim + ArktsProxy；台标 = 修正 metadata 推送时机** | ✅ 落地 / 台标**在修** |
| **第九战役** | **方案 B 原生解密可行性** | **wasm2c 解密核心已证可行**（6/6 逐字节一致） | ✅ 解密可行 / ⏸ **整体冻结**（瓶颈在 AVPlayer demux） |

---

## 十五、优化方向（2026-09 当前判断）

### 15.1 已关闭的方向（**勿重复投入**）

| 方向 | 结论 | 依据 |
|---|---|---|
| 用标准 hls.js + 自写 `cmgdec` 桥替换官方 `hls.cmg.js`（V2 再瘦身） | **失败，已放弃** | 桌面/真机 `diffBytes=0` 绿屏，仅 CCTV-6（**不加密**）能播；官方 `hls.cmg.js` 内部有未识别的解密前置逻辑。**Node 里"能解密"不代表浏览器里能解密**。收益仅省 704KB，性价比低（§11.3） |
| 伪装 `window.location` / `Location.prototype` | **注定失败**（此结论仍成立） | Chromium 中二者都是不可配置的 own accessor。**但根本不需要走这条路**——hook `eval` + emval 即可（§10.2） |
| 强制 `global 9=2` wasm 补丁 / 直接调 `_CMG_InitPlayer` | 有害 / 无效 | 见 §4.3 |
| 手动 `createAVSession` 控制播控中心 | **会导致媒体卡片消失**（**三次**复现） | §12.4 |
| "纯 Node 必恒等 ⇒ 方案 B 死刑" | **假命题，已证伪** | §10.6 / §13.2 |
| "回看缺 VOD 解密入口" | **假命题，已证伪** | §16.1 |

### 15.2 高性价比（低风险、可直接做）
1. **VMPATCH3 参数化**：扫描范围 `6684672~6698000` 目前是**硬编码**，与 wasm 版本绑定。改为**自动探测非零 4KB 块**并对 wasm 版本（`V=1.2.1` / `CMG_BTime=Aug 13 2025`）做断言——上游更新时**直接报错**，而不是静默花屏。
2. **`sapi_cache` 自动失效**：对比上游响应头/长度，变化则重抓并**自动重跑 `verify_inject.cjs`**。这能根治那个反复踩的坑：上游更新 → 注入串未重新校验 → 整段 `hls.cmg.js` 语法错 → 报「Hls 不支持」。
3. **签名单元测试**：HAR 黄金值已有（`md5(...+Ac)`、`6891575e8cec600a31c763e68be0015a`、`rnd=364e7007be98cafbdcb5950778dfa85d`），加 CI 防盐值/排序回归（§七）。
4. **`eb_prog` / `reloc` 传输压缩**：gzip 后 140,645B（62.9%）/ 4,799B。作**独立文件**由服务端 gzip 传输即可；**不要**解压后内联（`ATPRERUN` 是同步的）。
5. **工程增强**：代理崩溃自重启；设置面板（端口/清晰度/缓冲长度/EPG 间隔/kvcollect 开关）；多天 EPG（换 `yyyyMMdd`）；字幕/多音轨；音量与进度持久化。

### 15.3 中等成本（需评估）
1. **多清晰度**：`defn` 支持 `fhd/shd/4k/8k`。⚠️ **已知风险**：8K 高码率下 VMPATCH3 的"跳过 diff>2KB 的块"保护位可能**误跳 wasm worker 活跃块** → 与 worker 竞争 → buffer error。需要独立的 8K 热修补策略。
2. **频道表自动化**：`CctvApi.Channels` 目前硬编码 pid/cnlId，官方加台会失效。改为自动拉取 + pid/cnlId 校验/自愈。
3. **跨平台**：目前 `win-x64` only（WebView2 是 Windows 专有），Linux/macOS 需 CEF / WebKit2。**好消息**：方案 A 的**内核无关性已被鸿蒙 ArkWeb 验证**，移植到 CEF 风险可控。

### 15.4 战略级（慎入）
1. **方案 B（wasm2c + AVPlayer / `OH_AVDataSource`）**：解密核心已证可行，剩余成本 = **TS 解析/重封装 + 自研 mini-HLS 客户端**（片段缝合 + PTS 连续性 + discontinuity）+ 非定长 NALU 长度改写，且需**鸿蒙 6.0(API20)+**。建议**仅在**「方案 A 的 WebView 体验（冷启动 1~2s）确实不可接受」时启动（§十三）。
2. **回看 / VOD**：见 §十六。

---

## 十六、★ 回看 / VOD：**解密能力根本不是瓶颈**

> 本节**推翻**旧结论「wasm 只导出 Live 解密路径、没有 VOD 解密入口」。

### 16.1 VOD 解密路径**完整存在**
- wasm **导出 `_CMG_jsdecVOD0..8`**（`na..va = func[73..105]`），与 Live 侧一一对应。
- `fG.StaticCallModuleVod` 有 **10 个方法**、`StaticCallModuleVodMap = [0..6]`、`StaticCallModuleVodAPI` 存在。
- `moduleDecData(jC, jD, jE, jF)` 的第 4 个参数 `jF` 本就是 **`'live' | 'vod'`** —— **调用方天然支持两种模式**。
- 槽位映射也是一致的：功能名索引 8 = `MpegAudio` → `_CMG_jsdecLive8` / `_CMG_jsdecVOD8`。

### 16.2 那回看到底卡在哪？
**只剩一件事：拿到移动端（App）的回看 m3u8 接口。** 解密能力**不是**瓶颈，**不要再把它当成 blocker**。

历史上失败的真正原因（README 8.2 有记载）：
- 本项目逆向的是**网页版**（yangshipin.cn），而**网页版本身没有"回看"功能**——回看只存在于**移动端 App**。
- 曾尝试用**多个 Android 模拟器**抓 App 的回看请求，但模拟器内 **TLS 握手始终失败**，一次官方回看请求都没抓到 → 回看 playurl API 与签名参数无法逆向 → 全链无法推进，实验代码已全部 revert。

### 16.3 若将来重启，可行的前置条件
1. **真机抓包**：root / jailbreak + Charles/Fiddler + **证书固定绕过**（如 Frida hook `checkServerTrusted`），先把真实的回看请求抓下来。这是**唯一的前置条件**。
2. **隐藏的 Web 入口**：`capi` 的节目数据里可能带 `vid`，可探测是否存在网页可用的 VOD 端点（成本最低，值得一试）。
3. **VOD 解密 wasm**：若回看流需要独立解密，从移动端提取对应 VOD wasm 并复刻注入链——但按 §16.1，**当前这个 wasm 很可能已经够用**。

### 16.4 顺带：直播内时移（in-live seek）仍未实现
- **现状**：`IsCurrent`（当前节目**红色高亮**）已实现；但**时移 / 已播节目回退播放没有实现**（代码中无任何 seek 相关实现）。
- **原理可行**：HLS 直播有滑动窗口，`v.currentTime = hls.liveSyncPosition - offsetSec` 即可在窗口内回退到节目起点，配合 EPG 的 start/end 就能做"刚才那段重播"。
- ⚠️ **注意**：CMG 解密是**有状态的**，跨越 wasm 密钥窗口的 seek **可能需要重新 `InitPlayer`**。

---

### 附录 A：关键文件清单
- `d:/TV/CCTV/cctv-proxy/main.go` —— 代理 + 注入 + 缓存
- `d:/TV/CCTV/cctv-proxy/build.ps1` —— 校验 → build → 覆盖 bin
- `d:/TV/CCTV/cctv-proxy/verify_inject.cjs` —— 注入串语法校验
- `d:/TV/CCTV/CCTVPlayer/player.html` —— 播放页（网络拦截 + cKey/yspticket 注入 + **三大种子补丁**）
- `d:/TV/CCTV/CCTVPlayer/MainWindow.xaml.cs` —— **默认本地导航 `127.0.0.1:18888/player`**（`--nav=official` 切官网 A/B）+ kvcollect 心跳（自动重载已随 VMPATCH3 废弃）
- `d:/TV/CCTV/CCTVPlayer/bin/Debug/net10.0-windows/win-x64/` —— 运行目录（exe + `sapi_cache/` + `cctv-debug.log` + `cctv-proxy.log`）
  - ⚠️ `dotnet build` 增量**不会复制** `player.html`（`PreserveNewest` 按时间戳判断），改完必须手动 `Copy-Item` 到 bin。
- **slim 资产（放在 `sapi_cache/`，随 exe 发布）**：`assets_2025_wasm_cmg.slim.js`(186KB) / `assets_2025_wasm_eb_prog.bin`(378,592B) / `assets_2025_wasm_reloc_table.bin`(40,960B)
- `d:/TV/CCTV/rev/gen_slim.cjs` —— 生成 `cmg.slim.js`（**eval hook / emval origin Proxy / eb_prog 外置**都在这里）
- `d:/TV/CCTV/rev/gen_hm_inline.cjs` —— 把 slim + 资产内联进鸿蒙 `player.html`（**强制替换旧内联块**）
- `d:/TV/CCTV/CctvPoC/entry/src/main/ets/pages/Index.ets` —— 鸿蒙主页面，**改 `player.html` 必须 `PLAYER_DEPLOY_VER` +1**
- `d:/TV/CCTV/cmg_c.c` + `wasm-rt.h` —— **wasm2c 原生解密移植**（方案 B 核心，`emval_as` 已修，见 §13.2）
- 反编译：`cmg.wat` / `cmg_decrypt.wasm`；wabt：`wabt反编译工具/bin/wat2wasm.exe`
- 官方源：`央视频官方源文件/hls.cmg.js`、`cmg.worker.js`、`CMGPlayer.json`

### 附录 B：密钥槽 / 调用点速查
- 解密调用点：`hls.cmg.js` idx≈210867，`fG[wz(0x6bf)](module, ts, nalu, key)`。
- 控制函数：`fG[wz(0x909)]`（InitPlayer/UpdatePlayer/UnInitPlayer 派发）。
- wasm 导出：`ba=_CMG_InitPlayer`(func71)、`ca=_CMG_UnInitPlayer`(func254)、`da=_CMG_UpdatePlayer`(func176)、`ea..ma=_CMG_jsdecLive0..8`(func91..99)、**`na..va=_CMG_jsdecVOD0..8`(func73..105)**。
  - ★ 2026-09 更正：**VOD 导出确实存在**（旧附录漏记，并由此误导出"没有回看解密能力"的错误结论，见 §十六）。
- 双密钥槽：路径1 `fG[0x9d2]="live"`(key_index 43, IDR/SPS) / 路径2 `fG[0x22f]`(P/B)。
- `mediaTagId` = `Date.now()` 时间戳（由 hls.js 从 config 填，非 m3u8 来）。
- **解密槽位（功能名索引，Proxy 实测）**：8=`MpegAudio`→`_CMG_jsdecLive8`/`_CMG_jsdecVOD8`；7=H264NalSet；6=H265NalData；5=AVS1AudioKey；4=HEVC2AAC；3=HASHMap；2=BASE64Dec；1=MediaSession；0=Mp4fragment。
- **`jsdecLive8` 调用签名（4 参数，已实证）**：`_CMG_jsdecLive8(tagIdPtr, naluPtr, naluLen, urlLen)`，返回输入长度、**原地写回**。内存布局 `[nalu][activeURL charCodes][mediaTagId charCodes]`。
- **`moduleDecData(jC=module, jD=mediaTagId, jE=nalu, jF='live'|'vod')`**：每次解密都是一次**完整独立的往返**（URL 与 key 每次重传）→ **必须逐 NALU**，漏一个即花屏。第 4 参 `jF` 天然支持 `'vod'`。

### 附录 C：自动重载参数（C# `CheckAutoReload`）— VMPATCH3 上线后已废弃

| 参数 | 值 | 含义 |
|------|-----|------|
| `ratio` 阈值 | 0.25 (25%) | `same=Y` 占比超过此值时触发重载 |
| 检查间隔 | 每 20 帧 | 避免每帧都计算比率 |
| 起始保护 | 前 200 帧不触发 | 防止初始阶段误判 |
| 冷却时间 | 25s | 两次重载最小间隔 |
| 重置方式 | `PlayChannel` → `Navigate` | 完全重建页面 + wasm 会话 |

### 附录 D：VMPATCH3 关键参数

| 参数 | 值 | 含义 |
|------|-----|------|
| Snapshot 时机 | T+6s（InitPlayer 完成后） | 确保 wasm 内存已完全初始化 |
| 扫描范围 | `0x660000` ~ `0x663000`（6.3~6.7MB） | wasm 线性内存全局数据段 |
| 对比/还原间隔 | 2s | 远小于 17s 衰减窗口 |
| 还原粒度 | 4KB 页内逐字节 | 仅还原变化字节 |
| 典型还原量 | ~9600 字节/次（3 个 4KB 块） | @6689120/@6693216/@6697312 |
| 性能开销 | < 5ms/次 | 不影响帧率 |

### 附录 E：新版诊断日志
| 日志 | 含义 |
|------|------|
| `[CMG] #N same=Y/N t=X in=.. out=.. ts=..` | 紧凑周期性健康检查（每 200 帧，首次 60 帧全量） |
| `[VMPATCH3] snapshot N blocks` | wasm 内存初始快照完成 |
| `[VMPATCH3-FIX] N bytes reset` | 检测到计数器累积并还原（正常，每 2s 一次） |
| `[AUTO-RELOAD] same=Y ... reloading XXX` | （已废弃）C# 层触发自动重载 |
| `[KVC] 心跳 OK` | kvcollect 遥测心跳发送成功 |
| `[REKEY] ctx=... decLog=...` | （已废弃）wasm 密钥轮换尝试 |
| `[WASM-WRAP] wrapped _CMG_*` | 页面加载/wasm 包装完成，每次重载出现 1 次 |
