/**
 * Index - 央视频 ArkWeb 壳主页
 *
 * 职责：
 *  - 拉起/守护 Go 代理 (hmos_proxy)，预取 /player（注入后播放器页）
 *  - Web 组件真实导航 https://www.yangshipin.cn（wasm 密钥 location 种子依赖）
 *  - onInterceptRequest 拦截主文档 → 返回预取播放器页（其余资源已由 Go 改写为绝对
 *    {HMOS_PROXY_BASE}，经 CORS 直达代理，无需在同步回调内转发）
 *  - mixedMode(All) 放行 https 页面内 http://127.0.0.1|局域网 子资源
 *  - javaScriptProxy 注册 __nativeBridge（收页面 postMessage 日志/错误）
 *  - runJavaScript 驱动 __genTokenRnd/__genCKey/__genYspTicket/__generateSignature/__startM3u8
 *  - 频道切换 + EPG 节目单
 */
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { audio } from '@kit.AudioKit';
import { avSession } from '@kit.AVSessionKit';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CctvChannel, Channels, channelName, channelsByGroup, channelIcon } from '../common/ChannelList';
import { ProxyClient, AuthResult } from '../common/ProxyClient';
import { ProxyLauncher, ProxyMode } from '../common/ProxyLauncher';
import { RawfileDeploy } from '../common/RawfileDeploy';
import { YspAppId, Guid, NavUrl, ProxyDefaultHost, ProxyPort, Ua } from '../common/CctvConfig';
import { buildUrl, getText } from '../common/CctvHttp';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';

const WAIT_HTML: string =
  '<!doctype html><html><head><meta charset="utf-8"></head>' +
    '<body style="background:#000;color:#888;display:flex;align-items:center;justify-content:center;' +
    'height:100vh;margin:0;font-family:sans-serif;">代理初始化中，请稍候…</body></html>';

/** ★ player_boot.html 部署版本号。
 *  ★★ 每次修改 rawfile/web/player.html（或 RawfileDeploy 注入逻辑）都要 +1，
 *    否则升级安装时 player_boot.html「缓存命中」会继续用旧内容，改动不生效。
 *    版本标记文件：{filesDir}/proxy/web/player_boot.ver（部署成功后写入本值）。
 */
const PLAYER_DEPLOY_VER: number = 3;

interface TabDef {
  label: string;
  value: number;
}
const TabDefs: TabDef[] = [
  { label: 'CCTV', value: 0 },
  { label: '卫视台', value: 1 },
  { label: '地方台', value: 2 }
];

interface EpgItem {
  name: string;
  start: string;
  end: string;
  isCurrent: boolean;   // 是否为当前正在播放的节目（红色高亮）
  day?: number;         // 0=今天, 1=明天（跨天节目单标注）
}

/** 鉴权链 sign 结果（ArkTS 不支持未类型化对象字面量） */
interface SignResult {
  input: string;
  bodySig: string;
}

// ★ 提取为 interface，符合 ArkTS 规范
interface AvoidAreaInfo {
  statusBarH: number;   // 顶部状态栏高度(vp)
  navBarH: number;      // 底部导航栏高度(vp)
}

/** 从 EPG 原始时间字符串中提取 HH:mm（兼容 "09:30" / "09:30:00" / "2026-08-15 09:30:00" 等格式） */
function fmtEpgTime(t: string): string {
  if (!t) {
    return '';
  }
  const m = /(\d{1,2}):(\d{2})/.exec(t);
  if (m) {
    return m[1] + ':' + m[2];
  }
  return t;
}

/** 判断某节目是否为当前正在播放（对齐桌面版 IsCurrent：HH:mm → 分钟比较，处理跨凌晨节目） */
function isNowPlaying(start: string, end: string): boolean {
  const s = parseMin(start);
  const e = parseMin(end);
  if (s < 0 || e < 0) {
    return false;
  }
  const d = new Date();
  let now = d.getHours() * 60 + d.getMinutes();
  let ee = e;
  if (ee <= s) {
    ee += 24 * 60;            // 跨凌晨节目（如 23:50-00:10）
  }
  if (now < s && ee >= 24 * 60) {
    now += 24 * 60;           // 凌晨时段归一化
  }
  return now >= s && now < ee;
}

/** 将 "HH:MM" 解析为分钟数；格式不符返回 -1 */
function parseMin(t: string): number {
  if (t && t.length >= 5 && t[2] === ':') {
    const h = parseInt(t.substring(0, 2), 10);
    const m = parseInt(t.substring(3, 5), 10);
    if (!isNaN(h) && !isNaN(m)) {
      return h * 60 + m;
    }
  }
  return -1;
}

@Entry
@Component
struct Index {
  controller: webview.WebviewController = new webview.WebviewController();
  @State proxyOk: boolean = false;
  @State statusText: string = '初始化中…';
  @State playerState: string = 'IDLE';
  @State currentName: string = 'CCTV-1 综合';
  @State showEpg: boolean = false;
  @State epgTitle: string = '';
  @State epgItems: EpgItem[] = [];
  @State upcomingEpg: EpgItem[] = [];   // ★ 竖屏下方"当前+未来8小时"节目单
  @State loading: boolean = false;
  @State isFullscreen: boolean = false;
  // ★ 2026-08-16: 新版 UI
  @State currentTab: number = 0;            // 0=CCTV 1=卫视 2=地方
  @State currentGroupChannels: CctvChannel[] = channelsByGroup('cctv'); // 当前 Tab 显示的频道列表
  @State paused: boolean = false;           // 视频暂停状态
  @State muted: boolean = true;             // 静音状态（视频默认静音启动）
  @State volume: number = 1.0;              // 音量 0~1
  @State currentEpg: string = '';           // 当前节目名（节目单条用）
  @State gestureBrightness: number = 1.0;    // 屏幕亮度 0~1 (全屏手势调节), 用 gestureBrightness 避免与 CommonAttribute.brightness 冲突
  @State controlsVisible: boolean = false;  // 默认隐藏, 只有触摸后才显示
  @State screenLocked: boolean = false;     // ★ 全屏锁屏: 锁定后隐藏控件+禁用手势, 仅右上角锁按钮可操作
  @State gestureHint: string = '';          // 手势调节提示文本(音量/亮度), 空串则隐藏
  @State videoNotice: string = '';          // ★ 视频区中央友好提示(如"应版权方要求暂停直播")，空串则隐藏
  @State channelIconMap: Record<string, image.PixelMap> = {};   // ★ 频道 id → 图标 PixelMap（UI 圆形频道图）
  @State activeChannelId: string = Channels[0].id;   // 当前播放频道
  private controlsTimer: number = -1;       // 控件自动隐藏计时器
  // ★★★ 全屏手势状态 (右半区=音量, 左半区=亮度)
  private gestureActive: boolean = false;
  private gestureSide: 'vol' | 'bri' | '' = '';
  private gestureStartY: number = 0;
  private gestureStartVol: number = 1;
  private gestureStartBri: number = 1;
  private videoZoneWidth: number = 0;       // 视频区宽度 (用于左右半区判断)
  // ★★★ 2026-08-17: 视频区尺寸自适应 (手机/平板/电脑, 横竖屏):
  //   非全屏保证 16:9 画面完整显示: 宽度×9/16 超过可用高度时按高度适配、收窄宽度(三个控件跟随在画面内)
  @State videoZoneHeight: number = 220;     // 视频区高度(vp, 非全屏)
  @State videoWidth: number = 0;            // 视频区宽度(vp, 非全屏): 横屏时收窄保证完整显示
  @State isPortrait: boolean = true;        // ★ 竖屏检测（频道栏 5 列布局用）
  @State iconSize: number = 64;             // ★ 频道图标容器尺寸(vp)，随屏宽动态计算(短边×18%)
  @State statusBarH: number = 26;           // ★ APP状态栏高度(vp), 横屏右侧频道列表定位用
  @State sideGap: number = 0;              // ★ 横屏窗口模式两侧间隙(vp), 左右一致
  @State channelListW: number = 0;         // ★ 横屏窗口模式频道列表宽度(vp)
  @State programBarH: number = 28.6;         // 节目条精确高度，由 onAreaChange 更新
  @State winW: number = 0;                 // 缓存窗口宽(vp)
  @State winH: number = 0;                 // 缓存窗口高(vp)
  private originalBrightness: number = -1;  // 全屏时亮度基准: -1=系统默认(退出全屏时恢复)
  private winObj: window.Window | null = null;  // 缓存主窗口(亮度调节用)
  private resizeHandler: (() => void) | null = null; //长期监听成员，在 aboutToAppear 注册、aboutToDisappear 注销

  // ★★★ 系统媒体音量: 直接调节系统音量(AudioManager.setVolume), 系统音量条/物理音量键同步
  private audioMgr: audio.AudioManager | null = null;  // AudioManager 实例
  private volMin: number = 0;    // 系统媒体音量最小档
  private volMax: number = 15;   // 系统媒体音量最大档
  private volCur: number = 15;   // 当前系统媒体音量档
  private audioSessionManager: audio.AudioSessionManager | null = null;  // ★ 音频会话管理器（短音焦点策略）
  private audioSessionActive: boolean = false;  // ★ AudioSession 是否已激活
  // ★ AVSession（媒体卡片：标题/台标/播控中心展示）。与 AudioSession 完全独立——
  //   它不参与音频焦点，故手动创建对"音频独占/上架合规"零影响。
  private avSession: avSession.AVSession | null = null;
  // ★ 前后台策略：直播时效性强，退后台 → 暂停+停止拉流+隐藏媒体卡；
  //   回前台离开<10s 续播，≥10s 重新鉴权起播（m3u8/TS 大概率已过期）。
  private bgSince: number = 0;                        // 退后台时刻；0=从未退后台
  // ★ 说明：AudioManager.on('interrupt') 为 deprecated(7/9/11) 旧 API 且本 SDK @kit 下类型不可用；
  //   现代 on('audioInterrupt') 只挂在 AudioRenderer 上，而本 App 音频由 ArkWeb <video> 内部渲染、
  //   拿不到 renderer —— 故不注册打断监听。打断场景由「前后台策略」兜底（退后台暂停、
  //   回前台续播/重播），且 AudioSession 恒为 SHARE/MIX 不抢焦点，合规无虞。
  private bgHandler: () => void = () => { this.appToBackground(); };
  private fgHandler: () => void = () => { this.appToForeground(); };

  /** 初始化系统媒体音量: 读取档位范围与当前值 (AudioManager 为 deprecated API, 但仍是三方应用调系统音量的唯一途径) */
  private initSystemVolume(): void {
    try {
      this.audioMgr = audio.getAudioManager();
      const mgr = this.audioMgr;
      mgr.getMinVolume(audio.AudioVolumeType.MEDIA).then((v: number) => { this.volMin = v; });
      mgr.getMaxVolume(audio.AudioVolumeType.MEDIA).then((v: number) => { this.volMax = v; });
      mgr.getVolume(audio.AudioVolumeType.MEDIA).then((v: number) => {
        this.volCur = v;
        this.volume = (v - this.volMin) / Math.max(1, this.volMax - this.volMin);
      });
      console.info('[sysvol] 系统媒体音量初始化完成');
    } catch (e) {
      console.error('[sysvol] 初始化失败: ' + (e as Error).message);
    }
  }

  /** 按 0~1 比例设置系统媒体音量 (档位取整; 步进吸附由调用方完成) */
  private setSysVolumeByRatio(ratio: number): void {
    if (!this.audioMgr) { this.initSystemVolume(); return; }
    const level = Math.round(this.volMin + Math.max(0, Math.min(1, ratio)) * (this.volMax - this.volMin));
    this.volCur = level;
    this.audioMgr.setVolume(audio.AudioVolumeType.MEDIA, level).catch((e: BusinessError) => {
      console.error('[sysvol] 设置失败 code=' + e.code + ' msg=' + e.message);
    });
    // Web 内音量固定 1: 音量完全由系统媒体音量控制, 避免两层音量叠加
    this.evalJs('window.__setVolume && window.__setVolume(1)');
  }

  // ==================== AudioSession 音频焦点管理（合规） ====================
  // ★ 2026-08-30 官方审核要求：无论静音还是有声播放，都必须使用
  //   CONCURRENCY_MIX_WITH_OTHERS (share) 策略，与其他应用音频混合播放；
  //   绝不使用 PAUSE(pause) / STOP 独占策略打断其他音频。
  //   故音频焦点全程统一为 SHARE，静音/有声切换只影响图标，不切换并发模式。

  /** 初始化 AudioSessionManager */
  private initAudioSessionManager(): void {
    try {
      const audioMgr = audio.getAudioManager();
      this.audioSessionManager = audioMgr.getSessionManager();
      console.info('[audiosession] AudioSessionManager 初始化成功');
    } catch (e) {
      console.error('[audiosession] AudioSessionManager 初始化失败: ' + (e as Error).message);
    }
  }

  /**
   * 激活 AudioSession，统一使用 SHARE 策略（CONCURRENCY_MIX_WITH_OTHERS）。
   * ★ 合规要求：始终 share、不独占音频（不再区分静音/有声切换 PAUSE）。
   */
  private activateAudioSessionShare(): void {
    if (!this.audioSessionManager) {
      this.initAudioSessionManager();
      if (!this.audioSessionManager) return;
    }
    const strategy: audio.AudioSessionStrategy = {
      concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_MIX_WITH_OTHERS
    };
    this.audioSessionManager.activateAudioSession(strategy).then(() => {
      this.audioSessionActive = true;
      console.info('[audiosession] 激活成功 mode=MIX (share策略)');
    }).catch((e: BusinessError) => {
      console.error('[audiosession] 激活失败 code=' + e.code + ' msg=' + e.message);
    });
  }

  /** 停用 AudioSession（释放音频焦点，让其他应用恢复） */
  private deactivateAudioSession(): void {
    if (!this.audioSessionManager || !this.audioSessionActive) return;
    this.audioSessionManager.deactivateAudioSession().then(() => {
      this.audioSessionActive = false;
      console.info('[audiosession] 停用成功');
    }).catch((e: BusinessError) => {
      console.error('[audiosession] 停用失败 code=' + e.code + ' msg=' + e.message);
    });
  }

  /**
   * ★ 静音状态变更：仅更新图标状态。
   *   音频焦点策略已统一为 SHARE（见 activateAudioSessionShare），
   *   静音/有声切换不再切换并发模式。
   */
  private handleMuteChanged(newMuted: boolean): void {
    this.muted = newMuted;
  }

  // ==================== AVSession（媒体卡片：标题 / 台标 / 播控中心） ====================
  // ★ 2026-09-03 恢复（源自 backup_CctvPoC_20260830_clean，用户实测台标"完美解决"）。
  //   与 AudioSession 完全独立：AVSession 只负责"播控中心/媒体卡片展示"，不参与音频焦点，
  //   因此手动创建对"音频独占 / 上架合规"零影响；音频并发策略仍由上面的
  //   AudioSessionManager（恒定 SHARE/MIX）决定。

  /** 初始化 AVSession。必须 catch 6600101：ArkWeb 可能已先创建，那不是致命错误。 */
  private async initAVSession(): Promise<void> {
    if (this.avSession) {
      return;
    }
    try {
      // 类型用 'video'，与直播内容匹配
      this.avSession = await avSession.createAVSession(this.ctx, 'CCTVPlayer', 'video');

      // 播控中心点击"播放"
      this.avSession.on('play', () => {
        console.info('[avsession] 播控中心: 播放');
        // ★ 加 catch 防止后台 JS 执行失败抛异常
        this.evalJs('document.querySelector("video")?.play()').catch(() => {});
        this.syncPlaybackState(true);
      });

      // 播控中心点击"暂停"
      this.avSession.on('pause', () => {
        console.info('[avsession] 播控中心: 暂停');
        this.evalJs('document.querySelector("video")?.pause()').catch(() => {});
        this.syncPlaybackState(false);
      });

      // ★ 初始状态设为 PAUSE，等真正播放时再更新为 PLAY（避免无音频流时系统拒绝显示）
      await this.avSession.setAVPlaybackState({
        state: avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
        position: { elapsedTime: 0, updateTime: Date.now() }
      });

      // 激活（必须在命令注册完成后）
      await this.avSession.activate();
      console.info('[avsession] AVSession 创建并激活成功');
      // ★ 边界：创建期间用户已切后台（async 竞态）→ 立即销毁，避免后台仍显示媒体卡
      if (this.bgSince > 0) {
        try {
          this.avSession.deactivate();
          this.avSession.destroy();
        } catch (e) { /* 忽略 */ }
        this.avSession = null;
      }
    } catch (e) {
      const msg = (e as Error).message;
      // 6600101 表示 Session 已存在（ArkWeb 可能已创建），不算致命错误
      if (msg.indexOf('6600101') >= 0 || msg.indexOf('already exists') >= 0) {
        console.info('[avsession] AVSession 已存在，跳过创建');
      } else {
        console.error('[avsession] AVSession 初始化失败: ' + msg);
      }
    }
  }

  /** 同步 AVSession 播放状态（媒体卡片的播放/暂停角标） */
  private async syncPlaybackState(isPlaying: boolean): Promise<void> {
    if (!this.avSession) {
      return;
    }
    try {
      await this.avSession.setAVPlaybackState({
        state: isPlaying
          ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
          : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
        position: { elapsedTime: 0, updateTime: Date.now() }
      });
    } catch (e) {
      console.error('[avsession] 同步播放状态失败: ' + (e as Error).message);
    }
  }

  /**
   * 更新 AVSession 媒体元数据：台标走 mediaImage: PixelMap（PNG 透明图标合成到白底正方形画布）。
   * @param title 频道名
   * @param iconDataUrl 频道图标 data URL（data:image/...;base64,...）；空则只设标题
   */
  private async updateAVSessionMetadata(title: string, iconDataUrl: string): Promise<void> {
    if (!this.avSession) {
      return;
    }
    try {
      let pixelMap: image.PixelMap | null = null;

      if (iconDataUrl && iconDataUrl.startsWith('data:image')) {
        const base64 = iconDataUrl.split(',')[1];
        if (base64) {
          const helper = new util.Base64Helper();
          const decoded = helper.decodeSync(base64, util.Type.MIME);
          const src = image.createImageSource(decoded.buffer as ArrayBuffer);

          // 1. 先创建原图 PixelMap 读取真实尺寸
          const originalPm = await src.createPixelMap({
            desiredPixelFormat: image.PixelMapFormat.RGBA_8888
          });
          const info = await originalPm.getImageInfo();
          const srcW = info.size.width;
          const srcH = info.size.height;

          // 2. 取长边为基准，乘以边距系数，生成带白边的正方形画布
          const marginRatio = 1.1;
          const canvasSize = Math.round(Math.max(srcW, srcH) * marginRatio);
          const offsetX = Math.floor((canvasSize - srcW) / 2);
          const offsetY = Math.floor((canvasSize - srcH) / 2);

          // 3. 读取原图 RGBA 像素
          const srcRowBytes = srcW * 4;
          const srcBuffer = new ArrayBuffer(srcH * srcRowBytes);
          const area: image.PositionArea = {
            pixels: srcBuffer,
            offset: 0,
            stride: srcRowBytes,
            region: {
              size: { width: srcW, height: srcH },
              x: 0,
              y: 0
            }
          };
          await originalPm.readPixels(area);
          const srcU8 = new Uint8Array(srcBuffer);

          // 4. 创建白色正方形画布 (RGBA=255)
          const dstRowBytes = canvasSize * 4;
          const dstTotalBytes = canvasSize * dstRowBytes;
          const dstU8 = new Uint8Array(dstTotalBytes);
          dstU8.fill(255);

          // 5. ★ 关键修复：逐像素 Alpha 混合，透明像素与白色背景融合
          for (let row = 0; row < srcH; row++) {
            const srcOffset = row * srcRowBytes;
            const dstOffset = (offsetY + row) * dstRowBytes + offsetX * 4;
            for (let col = 0; col < srcW; col++) {
              const s = srcOffset + col * 4;
              const d = dstOffset + col * 4;
              const alpha = srcU8[s + 3] / 255.0;                    // A 通道归一化
              dstU8[d] = Math.round(srcU8[s] * alpha + 255 * (1 - alpha)); // R
              dstU8[d + 1] = Math.round(srcU8[s + 1] * alpha + 255 * (1 - alpha)); // G
              dstU8[d + 2] = Math.round(srcU8[s + 2] * alpha + 255 * (1 - alpha)); // B
              dstU8[d + 3] = 255;                                    // A = 不透明
            }
          }

          // 6. 释放原图资源
          await originalPm.release();
          await src.release();

          // 7. 从白底 buffer 生成新的正方形 PixelMap
          const opts: image.InitializationOptions = {
            size: { width: canvasSize, height: canvasSize },
            pixelFormat: image.PixelMapFormat.RGBA_8888,
            editable: true
          };
          pixelMap = await image.createPixelMap(dstU8.buffer, opts);
        }
      }

      if (pixelMap) {
        await this.avSession.setAVMetadata({
          assetId: 'cctv_' + title,
          title: title,
          artist: 'TVPlayer',
          mediaImage: pixelMap,
          duration: 0
        });
      } else {
        await this.avSession.setAVMetadata({
          assetId: 'cctv_' + title,
          title: title,
          artist: 'TVPlayer',
          duration: 0
        });
      }

      await this.syncPlaybackState(true);
      console.info('[avsession] 媒体元数据已更新: ' + title);

    } catch (e) {
      console.error('[avsession] 设置媒体元数据失败: ' + (e as Error).message);
    }
  }

  // ==================== 前后台 & 音频打断（直播后台策略） ====================

  /** 退后台：暂停 + hls.stopLoad() + 隐藏媒体卡（直播后台不显示卡片、不再拉流） */
  private appToBackground(): void {
    this.bgSince = Date.now();
    console.info('[lifecycle] 退后台：暂停拉流并隐藏媒体卡');
    // 1. 销毁 AVSession → 媒体卡从播控中心消失（避免"卡片一直显示、按钮无响应"）
    if (this.avSession) {
      try {
        this.avSession.deactivate();
        this.avSession.destroy();
      } catch (e) { /* 忽略 */ }
      this.avSession = null;
    }
    // 2. 已无播放 → 释放 AudioSession（不占任何音频焦点）
    this.deactivateAudioSession();
    // 3. 页面侧：v.pause() + hls.stopLoad()（最多播完已缓冲 TS，不再新拉）
    this.evalJs('window.__goBackground ? window.__goBackground() : 0').catch(() => {});
  }

  /** 回前台：离开<10s 短离续播；≥10s 重新走 auth→get_live_info→下载 的正常播放流程 */
  private async appToForeground(): Promise<void> {
    if (this.bgSince === 0) {
      return;   // 冷启动或未真正退过后台，忽略（避免误重启）
    }
    const gap = Date.now() - this.bgSince;
    this.bgSince = 0;
    console.info('[lifecycle] 回前台：离开 ' + gap + 'ms');
    // 恢复音频会话（SHARE/MIX，不独占）
    this.activateAudioSessionShare();
    // 重建媒体卡（标题/台标）
    await this.initAVSession();
    if (gap >= 10000) {
      // ≥10s：m3u8/TS 大概率过期 → 重新鉴权起播（playChannel 内含全套流程）
      console.info('[lifecycle] 离开≥10s，重新鉴权起播: ' + this.activeChannel.name);
      this.playChannel(this.activeChannel);
      return;
    }
    // 短离：重建媒体卡信息 + 恢复拉流
    const icon = await this.channelIconDataUrl(this.activeChannel.id);
    this.updateAVSessionMetadata(this.activeChannel.name, icon);
    this.evalJs('window.__goForeground ? window.__goForeground() : 0').catch(() => {});
    console.info('[lifecycle] 短离，恢复拉流播放');
  }

  /** 应用窗口亮度 (0~1): window.setWindowBrightness 仅主窗口生效, 退出应用自动恢复 */
  private applyBrightness(b: number): void {
    try {
      if (this.winObj) {
        this.winObj.setWindowBrightness(Math.max(0, Math.min(1, b)));
      }
      console.info('[gesture] brightness=' + b.toFixed(2));
    } catch (e) {
      console.error('[gesture] applyBrightness 失败: ' + e);
    }
  }

  /** 显示控件并重置 3s 自动隐藏计时 */
  private showControls(): void {
    this.controlsVisible = true;
    if (this.controlsTimer >= 0) {
      clearTimeout(this.controlsTimer);
    }
    this.controlsTimer = setTimeout(() => {
      this.controlsVisible = false;
      this.controlsTimer = -1;
    }, 3000);
  }

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private client: ProxyClient = new ProxyClient(this.ctx, '');
  private launcher: ProxyLauncher | null = null;
  private proxyBase: string = '';
  private playerHtml: string = '';
  private playing: boolean = false;
  private playRequestId: number = 0;
  private activeChannel: CctvChannel = Channels[0];
  private prevChannel: CctvChannel = Channels[0];   // ★ no-playurl 失败时回退用的原频道
  private lastAddressRefreshMs: number = 0;
  private kvTimer: number = -1;
  private warmTimer: number = -1;         // ★ 预热周期心跳定时器
  private noticeTimer: number = -1;       // ★ 视频区友好提示自动消失计时器(5s)
  private currentPid: string = '';
  private currentCnlId: string = '';
  private pageReady: boolean = false;
  private bootPlayed: boolean = false;
  // ★ 2026-08-21: open-token 502 自动重试节流（换台瞬间网络抖动，静默重试一次）
  private lastToken502RetryMs: number = 0;
  // ★ 2026-08-30: get-live-info 401 重试记录（按 pid，各允许换新 token 重试一次）。
  //   用 Set 而非「全局时间戳节流」，避免连续换不同频道时后者被误抑制。
  private auth401Retried: Set<string> = new Set<string>();

  // ★ Web 回调（ArkTS 严格模式下，build() 内 inline lambda 里用 this 不被允许，
  //   故抽出为类方法成员，确保 this 指向组件实例）
  private onMsgProxy = (msg: string): void => {
    this.handleBridgeMsg(msg);
  };

  private onIntercept = (event: OnInterceptRequestEvent | undefined): WebResourceResponse | null => {
    if (!event) {
      return null;
    }
    if (event.request.isMainFrame()) {
      const html = this.playerHtml.length > 0 ? this.playerHtml : WAIT_HTML;
      const resp = new WebResourceResponse();
      resp.setResponseData(html);
      resp.setResponseMimeType('text/html');
      resp.setResponseEncoding('utf-8');
      resp.setResponseCode(200);
      resp.setReasonMessage('OK');
      return resp;
    }
    return null;
  };

  private onPageEnd = (event: OnPageEndEvent | undefined): void => {
    if (event) {
      console.info('[cctv] 页面加载完成: ' + event.url);
    }
    this.pageReady = true;
    if (!this.bootPlayed) {
      this.bootPlayed = true;
      // ★ 冷启动优化(2026-08-30): 原先在代理就绪后盲等 setTimeout(500)，实测白等 ~460ms。
      //   该延时的历史用途是「等页面/wasm 就绪」，但这两个依赖都有各自的显式守卫：
      //     - keygen/yspticket wasm → playChannel 内部 await waitWasmReady()
      //     - CMG 模块 CNTVH5PlayerModule → 下方 waitCmgModuleReady() 轮询
      //     - CMG wasm 就绪 → 页面 __startM3u8 内部 __waitFirstPlay 轮询
      //   故改为等真实信号：就绪即播，省掉固定延时。
      this.waitProxyReady().then(async () => {
        await this.waitCmgModuleReady();
        this.playChannel(Channels[0]);
      });
    }
  };

  /**
   * 等待页面的 CMG 模块对象就绪（window.CNTVH5PlayerModule 已在页面加载时同步创建）。
   * 只等「对象已定义」，不等 wasm 编译完成——后者由页面状态机负责，避免这里重复等待。
   * 正常情况首查即命中（~10ms），仅作为超时保护。
   */
  private async waitCmgModuleReady(maxMs: number = 5000): Promise<void> {
    const deadline = Date.now() + maxMs;
    while (Date.now() < deadline) {
      try {
        const raw = await this.evalStr(
          `JSON.stringify(typeof window.CNTVH5PlayerModule!=='undefined')`);
        if (raw === 'true') {
          return;
        }
      } catch (e) {
        // 页面尚未就绪，继续轮询
      }
      await this.sleep(100);
    }
    console.warn('[cctv] CMG 模块对象等待超时，尝试继续播放');
  }

  /**
   * ★ 起播优化: 预热首次鉴权（代理就绪后立即执行，与 WebView 加载并行）
   *   提前完成 /auth + /open-token，后续 playChannel 直接复用缓存，跳过 2 次外网请求。
   */
  private preWarmAuth(): void {
    // ★ 按 pid 判定：只预热首播频道（Channels[0]）的 token
    if (this.client.hasCachedAuth(Channels[0].pid)) {
      return;  // 已有该频道缓存，无需预热
    }
    this.waitProxyReady(5000).then(() => {
      if (this.client.hasCachedAuth(Channels[0].pid)) {
        return;
      }
      console.info('[prewarm] 代理就绪，开始预热鉴权');
      // 冷启动时 WebView 可能尚未加载完成，wasm 不可用，
      // 故只能预热 auth（纯网络，不需要 wasm）；open-token 需要 wasm tokenRnd，
      // 留到 playChannel 中执行。
      // ★ ensureAuth 内部会写入缓存；playChannel 若在途会复用这个 Promise，不重复发 /auth
      this.client.ensureAuth(Channels[0].pid).then((a) => {
        console.info('[prewarm] auth 预热成功，token=' + a.token.substring(0, 8) + '...');
      }).catch((e: Error) => {
        console.info('[prewarm] auth 预热失败（非致命）: ' + e.message);
      });
    });
  }

  /** ★ 预热周期心跳：应用运行期间定时预热源站域名，保持 DNS/连接常热。
   *  ★ 2026-08-30 修正：心跳间隔必须 < 阈值 WARM_STALE_MS，否则「间隔 == 阈值」时，
   *    每次触发都恰好 now-lastWarmDnsAt 略小于阈值（lastWarmDnsAt 比心跳起点晚约 1s），
   *    导致隔一次才真正预热 → 实际间隔 2×阈值 = 6 分钟，踩在 DNS 失效点(6分38秒)边缘。
   *    改为阈值的一半(90s)，保证实际预热间隔 3~4.5 分钟，远小于失效点。 */
  private startWarmHeartbeat(): void {
    if (this.warmTimer >= 0) {
      clearInterval(this.warmTimer);
    }
    this.warmTimer = setInterval(() => {
      this.client.warmDnsIfStale(ProxyClient.WARM_STALE_MS);
    }, ProxyClient.WARM_STALE_MS / 2);
  }

  /** 等待代理就绪（最多 8s，每 100ms 探测一次） */
  private async waitProxyReady(maxMs: number = 8000): Promise<void> {
    const deadline = Date.now() + maxMs;
    while (Date.now() < deadline) {
      if (this.proxyOk) return;
      await this.sleep(100);  // 缩短到 100ms，减少等待延迟
    }
    console.warn('[proxy] 等待代理超时，尝试继续播放');
  }

  private onConsole = (event: OnConsoleEvent | undefined): boolean => {
    if (event && event.message) {
      console.info('[web-console] ' + event.message.getMessage());
    }
    return true;
  };

  /** 缓存的避让区域 */
  private avoidArea: AvoidAreaInfo | null = null;

  /**   * 刷新系统避让区域（状态栏 + 导航栏）   */
  private refreshAvoidArea(): void {
    try {
      if (!this.winObj) {
        if (this.avoidArea === null) {
          this.avoidArea = { statusBarH: 38, navBarH: 28 };
        }
        return;
      }
      const systemArea = this.winObj.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const navArea = this.winObj.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);

      const newTop = px2vp(systemArea.topRect.height);
      const newBottom = px2vp(navArea.bottomRect.height);

      const topH = newTop > 0 ? newTop : 38;
      const bottomH = newBottom > 0 ? newBottom : 28;

      // ★ 变化 < 2vp 时保持旧值，避免系统栏动画期间微小波动
      if (this.avoidArea !== null
        && Math.abs(this.avoidArea.statusBarH - topH) < 2.0
        && Math.abs(this.avoidArea.navBarH - bottomH) < 2.0) {
        return;
      }

      this.avoidArea = { statusBarH: topH, navBarH: bottomH };
    } catch (e) {
      if (this.avoidArea === null) {
        this.avoidArea = { statusBarH: 38, navBarH: 28 };
      }
    }
  }

  /**   * 重算窗口布局   */
  private recalcLayout(): void {
    try {
      const r = this.winObj ? this.winObj.getWindowProperties().windowRect : null;
      if (!r || r.width <= 0 || r.height <= 0) return;

      // 每次强制刷新避让区域，不缓存旧值
      this.refreshAvoidArea();

      const rw = px2vp(r.width);
      const rh = px2vp(r.height);

      this.winW = rw;
      this.winH = rh;
      this.isPortrait = rh >= rw;
      // ★ UX 合规: 折叠屏展开态图标不能超过折叠态的 1.2 倍，加 max cap
      this.iconSize = Math.min(Math.floor(Math.min(rw, rh) * 0.18), 110);

      // 总是调用，updateVideoSize 内部有自己的变化判断
      this.updateVideoSize();
    } catch (e) {
      console.error('[layout] 窗口尺寸重算失败: ' + (e as Error).message);
    }
  }

  /**   * 重算视频尺寸（核心修改：横屏正确扣除导航栏）   */
  private updateVideoSize(): void {
    if (this.isFullscreen) { return; }

    let W = this.winW;
    let H = this.winH;

    try {
      if (W <= 0 || H <= 0) {
        const r = this.winObj ? this.winObj.getWindowProperties().windowRect : null;
        if (r && r.width > 0 && r.height > 0) {
          W = px2vp(r.width); H = px2vp(r.height);
        }
      }
      if (W <= 0 || H <= 0) {
        const d = display.getDefaultDisplaySync();
        W = px2vp(d.width); H = px2vp(d.height);
      }
      this.winW = W; this.winH = H;
      // ★ UX 合规: 折叠屏展开态图标不能超过折叠态的 1.2 倍，加 max cap
      this.iconSize = Math.min(Math.floor(Math.min(W, H) * 0.18), 110);
    } catch (e) {
      console.error('[layout] 窗口尺寸获取失败: ' + (e as Error).message);
      return;
    }

    const isLand = W > H;
    const topH = this.avoidArea ? this.avoidArea.statusBarH : 0;
    const bottomH = this.avoidArea ? this.avoidArea.navBarH : 0;
    const usableH = Math.max(100, H - topH - bottomH);

    let w = W;
    let h = W * 9 / 16;
    let newChannelListW = 0;
    let newSideGap = 0;

    if (isLand) {
      // 视频可用高度 = 内容区总高 - 应用信息栏 - 节目条
      const availH = usableH - this.statusBarH - this.programBarH;

      // ★ 68:32 比例（原来是 60:40）
      const videoAreaW = W * 0.68;
      newChannelListW = W * 0.32;

      // 先按高度限制反推最大宽度（确保不溢出）
      const maxW = Math.floor(Math.max(160, availH) * 16 / 9);

      // 视频宽度 = min(65%区域宽, 按高度限制的最大宽)
      let vw = Math.min(videoAreaW, maxW);
      let vh = vw * 9 / 16;

      // 保证最小高度
      if (vh < 160) {
        vh = 160;
        vw = Math.floor(vh * 16 / 9);
      }

      // 在 65% 区域内水平居中
      newSideGap = (videoAreaW - vw) / 2;

      w = vw; h = vh;
    } else {
      const maxUsableH = Math.max(160, usableH - 100);
      if (h > maxUsableH) {
        h = maxUsableH;
        w = Math.floor(h * 16 / 9);
      }
    }

    // ★ 统一在这里判断变化并赋值，避免横屏提前赋值导致日志不打印
    if (Math.abs(this.videoWidth - w) > 2
      || Math.abs(this.videoZoneHeight - h) > 2
      || Math.abs(this.channelListW - newChannelListW) > 2
      || Math.abs(this.sideGap - newSideGap) > 2) {
      this.videoWidth = w;
      this.videoZoneHeight = h;
      this.videoZoneWidth = w;
      this.channelListW = newChannelListW;
      this.sideGap = newSideGap;
      console.info('[layout] 视频宽高=' + w.toFixed(1) + 'x' + h.toFixed(1)
        + ' 屏幕宽高=' + W.toFixed(1) + 'x' + H.toFixed(1)
        + ' 状态栏高=' + topH.toFixed(1) + ' 导航栏高=' + bottomH.toFixed(1)
        + ' 可用高=' + usableH.toFixed(1)
        + ' 视频可用高=' + (usableH - this.statusBarH - this.programBarH).toFixed(1)
        + ' 信息栏高=' + this.statusBarH.toFixed(1)
        + ' 节目单高=' + this.programBarH.toFixed(1)
        + ' sideGap=' + newSideGap.toFixed(1)
        + ' 频道栏宽=' + newChannelListW.toFixed(1));
    }
  }

  aboutToAppear(): void {
    this.initSystemVolume();
    this.initAudioSessionManager();  // ★ 合规修复: 初始化音频会话管理器
    // ★ 合规修复: 必须在任何音频播放前激活 AudioSession 为 SHARE 策略（MIX），
    //   否则系统会使用默认 STOP 策略打断其他音频。
    this.activateAudioSessionShare();
    // ★ AVSession（媒体卡片）与页面加载并行初始化，不阻塞冷启动。
    //   手动 createAVSession 是台标能显示的唯一可行方案（用户 2026-09-03 实测）；
    //   6600101(已存在) 已在 initAVSession 内按非致命处理。
    this.initAVSession().catch((e: Error) => {
      console.error('[avsession] 初始化失败，继续启动: ' + e.message);
    });
    // ★ 前后台订阅：退后台暂停+隐藏媒体卡；回前台短离续播/≥10s 重播
    try {
      this.ctx.eventHub.on('tvpBackground', this.bgHandler);
      this.ctx.eventHub.on('tvpForeground', this.fgHandler);
    } catch (e) {
      console.error('[lifecycle] EventHub 订阅失败: ' + (e as Error).message);
    }
    // ★ 冷启动优化: 图标加载延迟到首帧后，避免启动阶段 23 张图片 IO 抢占 CPU/带宽
    setTimeout(() => {
      this.loadChannelIcons(channelsByGroup('cctv')).catch(() => {});
    }, 500);
    // ★ preWarmAuth 已移至 runInit() 末尾（确保 client 已初始化，避免竞态）

    this.runInit();

    window.getLastWindow(this.ctx).then((w: window.Window) => {
      this.winObj = w;
      this.statusBarH = 26;            // ★ 固定值，与 Row 高度一致
      // ★ 初始化即允许跟随系统自动旋转，避免首次打开必须先点一次全屏再退出才能响应横屏
      w.setPreferredOrientation(window.Orientation.AUTO_ROTATION).catch((e: Error) => {
        console.error('[layout] 初始化方向失败: ' + e.message);
      });
      w.setWindowSystemBarEnable(['status', 'navigation']).catch((e: Error) => {
        console.error('[layout] 初始化系统栏、导航栏失败: ' + e.message);
      });
      // ★ 长期监听窗口尺寸变化（横竖屏切换、分屏、窗口化都会触发）
      this.resizeHandler = () => { this.recalcLayout(); };
      w.on('windowSizeChange', this.resizeHandler);
      this.recalcLayout();
    }).catch(() => {
      this.statusBarH = 28;            // 兜底
      this.updateVideoSize();
    });
  }

  aboutToDisappear(): void {
    if (this.kvTimer >= 0) {
      clearInterval(this.kvTimer);
      this.kvTimer = -1;
    }
    if (this.warmTimer >= 0) {
      clearInterval(this.warmTimer);
      this.warmTimer = -1;
    }
    if (this.launcher) {
      this.launcher.stopWatch();
    }
    if (this.resizeHandler && this.winObj) {
      try {
        this.winObj.off('windowSizeChange', this.resizeHandler);
      } catch (e) {}
      this.resizeHandler = null;
    }
    // ★ 取消前后台订阅
    try {
      this.ctx.eventHub.off('tvpBackground', this.bgHandler);
      this.ctx.eventHub.off('tvpForeground', this.fgHandler);
    } catch (e) {}
    if (this.avSession) { // ★ 销毁 AVSession（媒体卡片随应用退出消失）
      try {
        this.avSession.deactivate();
        this.avSession.destroy();
        this.avSession = null;
      } catch (e) {
        // 忽略
      }
    }
    // ★ 合规修复: 释放 AudioSession，让其他应用恢复音频焦点
    this.deactivateAudioSession();
  }

  async runInit(): Promise<void> {
    this.proxyBase = buildUrl(ProxyDefaultHost, ProxyPort, '');
    this.client = new ProxyClient(this.ctx, this.proxyBase);
    await this.client.init();

    // ★★★ 冷启动核心优化：三路并行启动
    //
    // 原流程（串行 ~1.5-3s）：
    //   proxy.start() → /health → getText('/player') → loadUrl(NavUrl)
    //
    // 新流程（三路并行）：
    //   路线1: proxy.start()          ← 后台启动（TCP 监听 + sapi）
    //   路线2: deploy+inject          ← 仅首次启动
    //   路线3: read(player_boot.html) → playerHtml=内存 → loadUrl(NavUrl)
    //
    // 后续启动：跳过路线2（player_boot.html 已缓存），只剩路线1+3（~0.2s）
    // 省去了 TCP 监听等待 + /health + HTTP GET /player + 运行时 WASM 注入。

    const resDir = this.ctx.filesDir + '/proxy';
    const bootPath = resDir + '/web/player_boot.html';

    // ★ 代理立即后台启动（与部署/页面渲染三路并行，不阻塞任何一方）
    this.launcher = new ProxyLauncher(this.proxyBase, ProxyMode.ARKTS, (ok: boolean, detail: string) => {
      this.proxyOk = ok;
      if (!ok) {
        this.statusText = detail;
      }
    }, this.ctx);
    this.launcher.ensure().then((ready: boolean) => {
      if (ready) {
        this.launcher!.startWatch();
        console.info('[proxy] 代理后台启动完成');
      } else {
        console.error('[proxy] 代理后台启动失败');
      }
    }).catch(() => {});

    // 1. 检查 player_boot.html 是否已存在 + 版本是否匹配（后续启动跳过部署，节省 ~300-500ms）
    const verPath = resDir + '/web/player_boot.ver';
    let needDeploy = true;
    try {
      const stat = fs.statSync(bootPath);
      needDeploy = stat.size <= 0;
    } catch (e) {
      needDeploy = true;  // 文件不存在，需要部署
    }
    // ★ 版本比对：player.html 修改后需 +1 PLAYER_DEPLOY_VER；
    //   版本标记不存在或不匹配 → 强制重新部署（否则升级安装会一直用旧 player_boot.html）。
    if (!needDeploy) {
      try {
        const vf = fs.openSync(verPath, fs.OpenMode.READ_ONLY);
        let verText = '';
        try {
          const vb = new ArrayBuffer(32);
          const vlen = fs.readSync(vf.fd, vb);
          const vtd = new util.TextDecoder('utf-8');
          verText = vtd.decodeWithStream(new Uint8Array(vb, 0, vlen), { stream: false }).trim();
        } finally {
          fs.closeSync(vf);
        }
        needDeploy = verText !== String(PLAYER_DEPLOY_VER);
      } catch (e) {
        needDeploy = true;  // 版本标记不存在 → 重新部署
      }
    }

    if (needDeploy) {
      // 首次启动（或版本升级）：部署 rawfile + 预注入 WASM → 生成 player_boot.html
      try {
        const deployed = await RawfileDeploy.deploy(this.ctx, resDir);
        if (!deployed) {
          this.statusText = '资源部署失败';
          return;
        }
        // ★ 写入版本标记
        try {
          const enc = new util.TextEncoder();
          const verBytes = enc.encodeInto(String(PLAYER_DEPLOY_VER));
          const vf2 = fs.openSync(verPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
          try {
            fs.writeSync(vf2.fd, verBytes.buffer as ArrayBuffer);
          } finally {
            fs.closeSync(vf2);
          }
        } catch (e) {
          // 写版本标记失败不影响播放（下次会重新部署，仅多花 ~300ms）
        }
      } catch (e) {
        this.statusText = '资源部署异常: ' + (e as Error).message;
        return;
      }
    }
    // ★ /sapi 本地注入缓存（幂等）：老版本升级上来时 needDeploy=false 但缓存可能缺失，
    //   这里补建；已存在时只是两次 statSync，开销可忽略。
    RawfileDeploy.buildSapiCache(resDir).catch(() => {
    });

    // 2. 直接读取预注入 HTML 内容到 this.playerHtml
    //    Web 加载 NavUrl → onIntercept 返回 playerHtml → 页面渲染 player.html
    try {
      const bootFile = fs.openSync(bootPath, fs.OpenMode.READ_ONLY);
      try {
        const stat = fs.statSync(bootPath);
        const buf = new ArrayBuffer(stat.size);
        const readLen = fs.readSync(bootFile.fd, buf);
        const td = new util.TextDecoder('utf-8');
        this.playerHtml = td.decodeWithStream(new Uint8Array(buf, 0, readLen), { stream: false });
      } finally {
        fs.closeSync(bootFile);
      }
      console.info('[runInit] player_boot.html 已读取 (' + this.playerHtml.length + ' bytes)' + (needDeploy ? ' (首次部署)' : ' (缓存命中)'));
    } catch (e) {
      console.error('[runInit] 读取 player_boot.html 失败: ' + (e as Error).message);
      // 回退：从代理获取（旧流程）
      const r = await getText(this.proxyBase, '/player', {}, 20000);
      if (r.code !== 0) {
        this.statusText = '播放器初始化失败';
        return;
      }
      this.playerHtml = r.body;
    }
    this.statusText = '播放器就绪，加载页面…';
    // ★ 起播优化: client 已初始化，立即预热首次鉴权（与 WebView 加载并行）
    this.preWarmAuth();
    // ★ DNS 预热（2026-08-30 实测）：h5access 首次解析 ~2.2s，与 auth 预热并行发起。
    //   auth 本身会预热 player-api，此处补 h5access（open-token 用）。
    //   预热后 open-token 从 ~2.2s 降到 ~110ms，是「sessionToken 改为每次现取」的前提。
    this.client.warmDns().catch(() => {
    });
    // ★ 周期心跳：每 WARM_STALE_MS 预热一次，保持鉴权链/DNS 常热，
    //   消除「长时间不换台后首次换台」的 ~4.4s 冷握手（见 ProxyClient.warmDnsIfStale 注释）。
    this.startWarmHeartbeat();
  }

  // ==================== 桥：页面 postMessage → 壳 ====================
  handleBridgeMsg(msg: string): void {
    try {
      const obj = JSON.parse(msg) as Record<string, string>;
      // 播放地址过期或网络连续失败时，重新走鉴权/签名/live-info，不能反复复用旧 m3u8。
      if (obj['type'] === 'refresh') {
        const now = Date.now();
        if (now - this.lastAddressRefreshMs < 10000) {
          return;
        }
        this.lastAddressRefreshMs = now;
        console.info('[cctv] 播放地址刷新: ' + String(obj['reason'] ?? '播放器请求'));
        this.playChannel(this.activeChannel);
        return;
      }
      if (obj['type'] === 'cmg') {
        const snapshot = obj['snapshot'] ? JSON.stringify(obj['snapshot']) : '';
        const detail = String(obj['detail'] ?? '');
        console.info('[player-cmg] stage=' + String(obj['stage'] ?? '') +
          ' detail=' + detail + ' ' + snapshot);
        if (obj['stage'] === 'timeout') {
          this.statusText = '播放器初始化失败';
        }
        return;
      }
      if (obj['type'] === 'audio') {
        // ★ 2026-08-30 修复: Web 侧 postMessage 传的是 JSON 布尔值（muted:true/false），
        //   经 JSON.parse 还原后 obj['muted'] 是 boolean，而旧代码 `=== 'true'` 只认字符串 →
        //   boolean true === 'true' 永远为 false，导致「静音启动」被误判为「有声音」，
        //   静音图标状态与真实 v.muted 错位。用 String() 统一转字符串比较，兼容两种类型。
        const isMuted = String(obj['muted']) === 'true';
        // ★ 静音状态变更时同步刷新静音图标
        this.handleMuteChanged(isMuted);
        return;
      }

      // 页面播放器状态机：只有收到首帧已渲染对应的 PLAYING，才显示“播放中”。
      // ★ 2026-08-21: 顶部信息栏简化，只显示固定文案，不显示 detail 调试后缀（正式版面向用户）。
      if (obj['type'] === 'state') {
        const state = String(obj['state'] ?? '');
        this.playerState = state;
        if (state === 'PLAYING') {
          this.statusText = '播放中';
          this.loading = false;
          // ★ 首帧真正渲染后才同步系统媒体卡片为"播放中"
          this.syncPlaybackState(true);
        } else if (state === 'PREPARING') {
          this.statusText = '准备播放中…';
          this.loading = true;
        } else if (state === 'BUFFERING') {
          this.statusText = '缓冲中…';
          this.loading = true;
        } else if (state === 'RECOVERING') {
          this.statusText = '网络波动，正在重试…';
          this.loading = true;
        } else if (state === 'ERROR') {
          this.statusText = '播放失败';
          this.loading = false;
        }
        return;
      }
      // ★ 页面点击 → 显示视频内控件
      const rawText = obj['log'] ?? obj['err'] ?? obj['error'] ?? obj['message'] ?? obj['msg'] ?? '';
      if (rawText === '__CTRL_SHOW') {
        this.showControls();  // 锁定也可显示控件(提供解锁入口), 滑动手势仍禁用
        return;
      }
      // ★ 2026-08-30: 未处理的 type（历史上如 media-metadata）会走到这里，
      //   取到的文本为空 → 打出一行空的 `[player] `。这里直接丢弃空文本，
      //   并对未知 type 打一条明确的提示，便于日后发现遗漏的分支。
      if (rawText.length === 0) {
        const unhandled = String(obj['type'] ?? '(无 type)');
        console.info('[player] 忽略无文本的桥接消息 type=' + unhandled);
        return;
      }
      // 页面侧 postMessage 直接使用 {log:'...'} / {err:'...'} / {error:'...'}
      const text = rawText;
      const isErr = obj['err'] !== undefined || obj['error'] !== undefined || (obj['type'] !== undefined && (obj['type'] === 'err' || obj['type'] === 'fatal'));
      if (isErr) {
        console.error('[player] ' + text);
        // ★ 2026-08-21: 顶部状态栏不显示原始调试日志，仅简洁提示
        this.statusText = '播放异常';
      } else {
        console.info('[player] ' + text);
      }
    } catch (e) {
      console.info('[player-raw] ' + msg);
    }
  }

  // ==================== runJavaScript 辅助 ====================
  // ★ 重要：ArkWeb runJavaScript 会把 JS 表达式的返回值再做一次 JSON 序列化。
  //   例如：脚本 JSON.stringify(true) 的 JS 返回值是字符串 'true'，但 runJavaScript
  //   返回给 ArkTS 的是 '"true"'（带双引号的 JSON 字符串）。因此拿到 raw 后必须
  //   JSON.parse 一次才能还原为脚本里 JSON.stringify 之前的目标值。
  async evalJs(script: string): Promise<string> {
    try {
      return await this.controller.runJavaScript(script);
    } catch (e) {
      throw new Error('runJavaScript: ' + (e as Error).message);
    }
  }

  /** 解析 JSON.stringify 包装的页面函数返回值 → 对象。
   *  raw = '"{\\"tokenRnd\\":\\"x\\"}"'，需 JSON.parse 两次（第一次去掉 runJavaScript
   *  的外层字符串包装，第二次把 JSON.stringify 的字符串还原为对象）。 */
  async evalObj(script: string): Promise<Record<string, Object>> {
    const raw = await this.evalJs(script);
    try {
      const first = JSON.parse(raw) as Object;
      // runJavaScript 可能已把字符串解包，也可能仍是字符串；统一再解析一次到对象
      if (typeof first === 'string') {
        return JSON.parse(first as string) as Record<string, Object>;
      }
      return first as Record<string, Object>;
    } catch (e) {
      throw new Error('页面返回非JSON: ' + raw.slice(0, 80));
    }
  }

  /** 解析 JSON.stringify 包装的页面函数返回值 → 字符串。
   *  ★ 需 parse 两次：脚本 JSON.stringify("abc") 的 JS 值是 '"abc"'，runJavaScript 再
   *  序列化一层成 '"\"abc\""'。第一次 parse 得 '"abc"'（仍带引号的字符串），
   *  再 parse 一次才得到裸值 "abc"。 */
  async evalStr(script: string): Promise<string> {
    const raw = await this.evalJs(script);
    try {
      const v = JSON.parse(raw) as Object;
      if (typeof v === 'string') {
        const v2 = JSON.parse(v as string) as Object;
        if (typeof v2 === 'string') {
          return v2 as string;
        }
        return v as string;
      }
      return raw;
    } catch (e) {
      return raw;
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => setTimeout(resolve, ms));
  }

  /**
   * 等待页面 wasm（keygen + yspticket）异步编译完成。
   * ArkWeb 禁止主线程同步编译 >4KB wasm，编译是异步的；这里轮询而非忙等，
   * 避免阻塞事件循环饿死微任务（wasmReady 的 .then 才能执行）。
   */
  private async waitWasmReady(maxMs: number = 20000): Promise<void> {
    const deadline = Date.now() + maxMs;
    while (Date.now() < deadline) {
      // ★ ArkWeb runJavaScript 会把 JSON.stringify 的结果再包一层 JSON 字符串：
      //   JSON.stringify(true) → 'true'，runJavaScript 返回 '"true"'（带引号）。
      //   因此这里用 evalStr（内部 JSON.parse 一次）拿到裸值，再判断。
      const raw = await this.evalStr(`JSON.stringify(!!(window.__wasmReadyAll && window.__wasmReadyAll()))`);
      if (raw === 'true') {
        return;
      }
      await this.sleep(200);
    }
    // 超时后收集详细诊断，便于定位是 keygen/yspticket 哪个失败
    const diagRaw = await this.evalJs(`JSON.stringify(typeof window.__wasmDiag==='function' ? window.__wasmDiag() : {note:'无诊断函数'})`);
    let diag = diagRaw;
    try {
      diag = JSON.stringify(JSON.parse(diagRaw));
    } catch (e) {
    }
    throw new Error('页面 wasm 初始化超时: ' + diag);
  }

  /** 读取频道图标 → data URL（用于系统媒体卡片 artwork）；失败返回空串 */
  async channelIconDataUrl(id: string): Promise<string> {
    try {
      const name = channelIcon(id);
      if (!name) {
        return '';
      }
      const b64 = await this.ctx.resourceManager.getMediaBase64ByName(name);
      // ★ 关键修复：getMediaBase64ByName 返回的已经是完整 data URL（含 data:image/png;base64, 前缀）
      //   如果再次拼接前缀 → data:image/png;base64,data:image/png;base64,xxx → 非法格式 → 解码失败
      if (!b64) {
        return '';
      }
      return b64.startsWith('data:') ? b64 : 'data:image/png;base64,' + b64;
    } catch (e) {
      console.info('[cctv] 频道图标读取失败: ' + (e as Error).message);
      return '';
    }
  }

  /** ★ 频道圆形图标项（台标），竖屏/横屏共用
   *  iconSize 随屏宽动态计算(短边×18%)；图标缩至 90% 再由正圆容器裁剪，
   *  避免圆角直接截断图标边缘导致失真。 */
  @Builder
  channelIconItem(ch: CctvChannel) {
    Stack({ alignContent: Alignment.Center }) {
      if (this.channelIconMap[ch.id] !== undefined) {
        Image(this.channelIconMap[ch.id])
          .width(Math.floor(this.iconSize * 0.9))
          .height(Math.floor(this.iconSize * 0.9))
          .objectFit(ImageFit.Contain)
      } else {
        Text(ch.name.substring(0, 1))
          .fontSize(Math.round(this.iconSize * 0.4))
          .fontColor('#333333')
          .textAlign(TextAlign.Center)
      }
    }
    .width(this.iconSize)
    .height(this.iconSize)
    .borderRadius(this.iconSize / 2)
    .backgroundColor('#ffffff')
    .clip(true)
    .border({
      width: 2,
      // color: this.currentName === ch.name ? '#ff3b3b' : '#3a3a3a'   // ← 旧 频道名
      color: this.activeChannelId === ch.id ? '#ff3b3b' : '#3a3a3a'   // ← 边框判断改用 id
    })
    .onClick(() => {
      this.playChannel(ch);
    })
  }

  /** ★ 2026-08-22: 频道分组 Tab + 频道列表（圆形图标），提取为 @Builder 供竖屏底部和横屏右侧复用 */
  @Builder
  channelTabsAndList() {
    // ── 分组 Tab 栏（胶囊分段控件）──
    Row({ space: 8 }) {              ForEach(TabDefs.filter((t) => {
            const g = t.value === 0 ? 'cctv' : t.value === 1 ? 'satellite' : 'local';
            return channelsByGroup(g).length > 0;
          }),
        (t: TabDef) => {
          Text(t.label)
            .fontSize(14)
            .fontColor(this.currentTab === t.value ? '#ffffff' : '#999999')
            .fontWeight(this.currentTab === t.value ? FontWeight.Bold : FontWeight.Normal)
            .textAlign(TextAlign.Center)
            .padding({ left: 18, right: 18, top: 6, bottom: 6 })
            .backgroundColor(this.currentTab === t.value ? '#2f6bff' : '#262626')
            .borderRadius(16)
            .onClick(() => {
              this.currentTab = t.value;
              const group =
                t.value === 0 ? channelsByGroup('cctv') :
                  t.value === 1 ? channelsByGroup('satellite') :
                    channelsByGroup('local');
              this.currentGroupChannels = group;
              this.loadChannelIcons(group).catch(() => {
              });
            })
        },
        (t: TabDef) => String(t.value))
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 4 })

    // ── 当前分组频道（圆形图标，正在播放的台外圈红色）──
    if (this.isPortrait) {
      // 竖屏：5 列网格布局，垂直滚动
      Scroll() {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.currentGroupChannels, (ch: CctvChannel) => {
            Column() {
              this.channelIconItem(ch)
            }
            .width('20%')
            .alignItems(HorizontalAlign.Center)
            .margin({ top: 3, bottom: 3 })
          }, (ch: CctvChannel) => ch.id)
        }
        .width('100%')
        .padding({ left: 4, right: 4, bottom: 6 })
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .height(this.iconSize * 2 + 14)
      .backgroundColor('#101010')
    } else {
      // ★ 横屏窗口模式: 3 列网格布局，垂直滚动（右侧频道列表）
      Scroll() {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.currentGroupChannels, (ch: CctvChannel) => {
            Column() {
              this.channelIconItem(ch)
            }
            .width('33.3%')
            .alignItems(HorizontalAlign.Center)
            .margin({ top: 3, bottom: 3 })
          }, (ch: CctvChannel) => ch.id)
        }
        .width('100%')
        .padding({ left: 4, right: 4, bottom: 6 })
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .backgroundColor('#101010')
    }
  }

  /** ★ 批量预取当前分组频道图标 → channelIconMap（PixelMap，UI 圆形频道图用，切 Tab 时调用）
   *  `$r('app.media.xxx')` 需字面量，动态资源名不可用；故用 `getMediaByName` 取原始字节，
   *  按 HarmonyOS 官方示例 createImageSource → createPixelMap(RGBA_8888) 生成 PixelMap。 */
  private async loadChannelIcons(channels: CctvChannel[]): Promise<void> {
    const next: Record<string, image.PixelMap> = {};
    const list: Promise<void>[] = [];
    for (const ch of channels) {
      list.push((async () => {
        try {
          const name = channelIcon(ch.id);
          if (!name) {
            return;
          }
          const u8 = await this.ctx.resourceManager.getMediaByName(name);
          const src = image.createImageSource(u8.buffer.slice(0, u8.buffer.byteLength));
          const pm = await src.createPixelMap({ desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
          await src.release();
          if (pm) {
            next[ch.id] = pm;
          }
        } catch (e) {
          console.info('[cctv] 频道图标加载失败: ' + ch.id + ' ' + (e as Error).message);
        }
      })());
    }
    await Promise.all(list);
    this.channelIconMap = next;
  }

  // ==================== 播放驱动 ====================

  async playChannel(ch: CctvChannel): Promise<void> {
    // 不丢弃用户的快速切台请求；旧请求完成后必须验证 requestId，禁止旧频道覆盖新频道。
    const requestId = ++this.playRequestId;
    this.prevChannel = this.activeChannel;   // ★ 保存原频道，待定频道失败时回退
    this.activeChannel = ch;
    this.activeChannelId = ch.id;        // ← 新增当前频道 ID 用于切台时验证
    this.playing = true;
    this.currentName = ch.name;
    this.currentPid = ch.pid;
    this.currentCnlId = ch.cnlId;
    this.statusText = '获取播放信息…';
    this.loading = true;
    this.videoNotice = '';   // ★ 开始切台/播放即清除视频区友好提示
    if (this.noticeTimer >= 0) {
      clearTimeout(this.noticeTimer);
      this.noticeTimer = -1;
    }
    // ★★ CMG 预建（2026-08-20）：与下方鉴权网络往返并行，提前创建新频道解密模块。
    //    切台时 __startM3u8 若发现 __cmgPrefetchedReady 则直接切换，跳过重建等待。
    //    不 await、失败忽略：绝不阻塞鉴权主流程。
    try {
      this.evalJs(`window.__cmgPrefetch(${JSON.stringify(ch.pid)}); true;`).catch(() => {
      });
    } catch (e) {
    }
    // ★ 合规修复: 播放前确保 AudioSession 已激活为 SHARE 策略（MIX）
    this.activateAudioSessionShare();
    // ★ 换台懒预热：距上次预热超阈值则异步补一次（不阻塞本次换台）。
    //   覆盖周期心跳漏掉/时序错位的场景，并预热本次可能用到的 CDN 域名。
    this.client.warmDnsIfStale(ProxyClient.WARM_STALE_MS);
    try {
      // ★★★ 起播优化核心：auth 缓存 + 并行化
      //
      // 有该 pid 的缓存 → 跳过 /auth；否则完整鉴权。
      // ★ 缓存按 pid 归档：auth token 绑定频道，跨频道复用必 401（见 ProxyClient 注释）。
      // ★ sessionToken 每次现取，不缓存。

      let a: AuthResult;
      let sessionToken: string = '';
      // ★ ensureAuth 是唯一鉴权入口：内部「查缓存 → 复用在途 → 发起并写缓存」三级逻辑，
      //   命中与否的日志也由它统一输出，这里不做任何冗余缓存探测（单次查询、单入口）。
      a = await this.client.ensureAuth(ch.pid);

      // 1.5 等待页面 wasm 编译就绪（编译在页面加载时已启动，此时通常已完成）
      await this.waitWasmReady();

      // ★ 2. 三条链路并行:
      //    链路A: tokenRnd → openToken（sessionToken 每次现取，不可缓存）
      //    链路B: cKey → sign
      //    链路C: yspticket
      const randStrLive = ProxyClient.genRandStr(10);
      const tsSec = String(Math.floor(Date.now() / 1000));
      const docUrl = 'https://yangshipin.cn/tv/home?pid=' + ch.pid;

      // ★ 链路B: cKey（wasm，~50ms）
      const cKeyPromise = this.evalStr(
        `JSON.stringify(window.__genCKey('${ch.cnlId}','${tsSec}','V1.0.0','${Guid}','5910204','${docUrl}'))`);
      // ★ 链路C: yspticket（wasm，~50ms）— 与 cKey 并行
      const yspTicketPromise = this.evalStr(
        `JSON.stringify(window.__genYspTicket('${ch.pid}','${a.authTs}','${ch.cnlId}','${Guid}','${YspAppId}','V1.0.0'))`);

      // ★ 链路A: tokenRnd → openToken（与 B/C 并行启动）
      //   sessionToken 每次现取：复用会让 get_live_info 返回 401（2026-08-30 实测）
      const sessionTokenPromise: Promise<string> = this.evalObj(
        `JSON.stringify(window.__genTokenRnd('${Guid}','${a.token}','${Date.now()}'))`
      ).then((trRaw: Record<string, Object>) => {
        const tokenRnd: string = trRaw['tokenRnd'] as string;
        if (!tokenRnd) {
          throw new Error('tokenRnd 失败: ' + String(trRaw['err'] ?? ''));
        }
        // openToken（网络，DNS 预热后 ~110ms）
        return this.client.openToken(a.token, a.authTs, tokenRnd);
      });
      // 兜底：若 B/C 链路先失败导致本函数提前返回，避免留下未处理的 rejection
      sessionTokenPromise.catch(() => {
      });

      // 等待链路B完成（cKey）
      const cKey = await cKeyPromise;

      // ★ 链路B 续: sign（网络，~200ms）
      const sdkFields: Record<string, string> = {
        'cnlid': ch.cnlId,
        'livepid': ch.pid,
        'stream': '2',
        'guid': Guid,
        'cKey': cKey,
        'adjust': '1',
        'sphttps': '1',
        'platform': '5910204',
        'cmd': '2',
        'encryptVer': '8.1',
        'dtype': '1',
        'devid': 'devid',
        'otype': 'ojson',
        'appVer': 'V1.0.0',
        'app_version': 'V1.0.0',
        'channel': 'ysp_tx',
        'defn': 'fhd',
        'rand_str': randStrLive
      };
      const signPromise: Promise<SignResult> = this.client.signSdkInput(sdkFields).then((input: string) =>
        this.client.signBody(sdkFields).then((bodySig: string): SignResult => ({ input: input, bodySig: bodySig }) as SignResult)
      );

      // ★ 等待 sign 完成
      const signResult: SignResult = await signPromise;
      const yspSdkInput: string = signResult.input;
      const bodySig: string = signResult.bodySig;

      // ★ auth 缓存由 ensureAuth 内部写入（命中在途请求时只写一次，不重复）

      // ★ 等待链路C完成（yspticket）
      const yspTicket = await yspTicketPromise;

      // ★ 等待链路A完成（sessionToken）— sig2 需要它
      sessionToken = await sessionTokenPromise;

      // ★ sig2（wasm，~50ms）— 需要 sessionToken + yspSdkInput，此时两者都已就绪
      const seqId2 = await this.client.nextSeqId();
      const ts2 = String(Date.now());
      const reqId2 = '999999' + ProxyClient.genRandStr(10) + ts2;
      const sigRaw = await this.evalObj(
        `JSON.stringify(window.__generateSignature('${ch.pid}','${Guid}','${seqId2}','${reqId2}','${sessionToken}','${ts2}','${yspSdkInput}'))`);
      const sig2 = sigRaw['signature'] as string;
      if (!sig2) {
        throw new Error('sig2 失败: ' + String(sigRaw['err'] ?? ''));
      }
      const yspSdkSign = sig2 + '-' + yspSdkInput + '-' + Guid + '-' + String(seqId2) + '-' + reqId2;

      // ★ get-live-info body
      const bodyJson = JSON.stringify({
        'cnlid': ch.cnlId,
        'livepid': ch.pid,
        'stream': '2',
        'guid': Guid,
        'cKey': cKey,
        'adjust': 1,
        'sphttps': '1',
        'platform': '5910204',
        'cmd': '2',
        'encryptVer': '8.1',
        'dtype': '1',
        'devid': 'devid',
        'otype': 'ojson',
        'appVer': 'V1.0.0',
        'app_version': 'V1.0.0',
        'channel': 'ysp_tx',
        'defn': 'fhd',
        'rand_str': randStrLive,
        'signature': bodySig
      });

      // 9. 获取 m3u8
      const live = await this.client.getLiveInfo(bodyJson, a.token, yspSdkInput, yspSdkSign,
        yspTicket, reqId2, seqId2);
      // 快速切台时，旧请求的鉴权结果不能再启动旧频道。
      if (requestId !== this.playRequestId) {
        return;
      }
      // ★ get_live_info 成功：刷新该频道的闲置计时，并解除 401 重试抑制
      this.client.markAuthUsed(ch.pid);
      this.auth401Retried.delete(ch.pid);

      // 10. 页面启动播放；页面状态机将在首帧真正渲染后才上报 PLAYING。
      const iconDataUrl = await this.channelIconDataUrl(ch.id);

      // ★ CMG 就绪等待已移除（2026-08-30）：
      //   JS 端 __startM3u8 内部的 __cmgRebuild 已经等待 WASM 就绪后才回调 go()。
      //   ArkTS 侧额外等待会导致5秒超时阻塞切台，反而让切台看起来“失败”。
      //   切台时 __cmgPrefetch 在鉴权期间提前启动，__startM3u8 的快速路径会直接使用预建模块。

      // ★ 同步 Web 播放器（CMG 未就绪时自动重试，最多 3 次，间隔 1s）
      let startResult = await this.evalJs(
        `window.__startM3u8(${JSON.stringify(live.m3u8)}, ${JSON.stringify(ch.pid)}, ${JSON.stringify(ch.name)}, ${JSON.stringify(iconDataUrl)})`);
      if (startResult === 'false') {
        // ★ CMG 可能尚未就绪（hasReady=false），等待 1s 后重试
        for (let retry = 0; retry < 3; retry++) {
          if (requestId !== this.playRequestId) return;
          console.info('[play] __startM3u8 返回 false，等待 CMG 就绪后重试 (' + (retry + 1) + '/3)');
          await this.sleep(1000);
          startResult = await this.evalJs(
            `window.__startM3u8(${JSON.stringify(live.m3u8)}, ${JSON.stringify(ch.pid)}, ${JSON.stringify(ch.name)}, ${JSON.stringify(iconDataUrl)})`);
          if (startResult !== 'false') break;
        }
        if (startResult === 'false') {
          throw new Error('播放器拒绝启动（CMG 重试 3 次仍失败）');
        }
      }
      // ★ 同步系统级媒体卡片（下拉栏播控中心）：标题 + 台标(PixelMap) + 播放状态。
      //   内部已 catch，失败不影响播放主流程。
      await this.updateAVSessionMetadata(ch.name, iconDataUrl);
      this.playerState = 'PREPARING';
      this.statusText = '缓冲中…';
      this.loading = true;
      this.startKv(ch.pid, live.playUrl);
      // ★ 后台静默拉 EPG：更新节目条 + 下方"当前+未来8小时"节目单（不弹窗，单请求）
      this.fetchUpcomingEpg(ch.pid);
    } catch (e) {
      if (requestId !== this.playRequestId) {
        return;
      }
      const msg = (e as Error).message;
      console.error('[cctv] 播放失败: ' + msg);
      // ★ 2026-08-21: open-token http 502（换台瞬间网络抖动）→ 静默自动重试一次，不显示调试日志。
      //   节流 3s：防止持续 502 时无限重试循环卡死。
      if (msg.indexOf('open-token http 502') >= 0) {
        const now = Date.now();
        if (now - this.lastToken502RetryMs > 3000) {
          this.lastToken502RetryMs = now;
          this.statusText = '缓冲中…';
          this.loading = true;
          console.info('[cctv] open-token 502，自动重试换台');
          // ★ 直接复用点击换台的完整逻辑（重新鉴权）重试当前频道
          this.playChannel(ch);
          return;
        }
      }
      // ★ 2026-08-30 第九轮：401 = 该频道的 auth token 被服务端判废。
      //   实测换新 token 后 4/4 成功，故**每个频道都允许重试一次**。
      //
      //   ★★ 这里原先是「全局 5s 节流」，是个真实缺陷：
      //     节流窗口内的 401 会被静默吞掉（不重试、不刷新 token），
      //     于是用户在 19:36:49 / 19:38:28 / 19:38:38 这几次看到的是**硬失败**，
      //     且该频道的坏 token 仍留在缓存里，下次切到它还会再 401。
      //     实测日志里 8 次 401 中有 4 次就是这样被吞掉的。
      //   改为按 pid 记一次：同一频道换新 token 重试过仍 401 才放弃（防死循环）；
      //   重试成功后由上面的 markAuthUsed 分支解除抑制。
      if (msg.indexOf('get-live-info http 401') >= 0) {
        if (!this.auth401Retried.has(ch.pid)) {
          this.auth401Retried.add(ch.pid);
          this.statusText = '缓冲中…';
          this.loading = true;
          console.info('[cctv] get-live-info 401（token 疑已失效），清除 pid=' + ch.pid + ' 鉴权缓存后重试');
          this.client.clearCachedAuth(ch.pid);
          this.playChannel(ch);
          return;
        }
        console.error('[cctv] get-live-info 401：pid=' + ch.pid + ' 换新 token 后仍失败，放弃重试');
      }
      // ★ 2026-08-21: 该频道未开播（get-live-info no playurl）→ 视频区显示友好提示，顶部不显示调试信息。
      if (msg.indexOf('get-live-info no playurl') >= 0) {
        this.playerState = 'ERROR';
        this.videoNotice = '【' + ch.name + '】频道暂未提供直播信号，请继续观看现频道，或点击其他频道进行观看';
        this.statusText = '播放失败';
        this.loading = false;
        // ★ 5 秒后自动消失：恢复原频道红色台标圈 + 信息栏恢复"播放中"
        if (this.noticeTimer >= 0) {
          clearTimeout(this.noticeTimer);
        }
        this.noticeTimer = setTimeout(() => {
          this.videoNotice = '';
          this.noticeTimer = -1;
          // ★ 回退红色台标圈到原频道（视觉上框回原频道图标）
          this.activeChannel = this.prevChannel;
          this.activeChannelId = this.prevChannel.id;
          // ★ 信息栏恢复"播放中"（原频道仍在播）
          this.statusText = '播放中';
          this.playerState = 'PLAYING';
        }, 5000);
        return;
      }
      this.playerState = 'ERROR';
      this.videoNotice = '';
      this.statusText = '播放失败';
    } finally {
      if (requestId === this.playRequestId) {
        this.playing = false;
        this.loading = this.playerState === 'PREPARING' || this.playerState === 'BUFFERING' || this.playerState === 'RECOVERING';
      }
    }
  }

  /** kvcollect 心跳（60s，失败自动忽略） */
  startKv(pid: string, durl: string): void {
    if (this.kvTimer >= 0) {
      clearInterval(this.kvTimer);
    }
    this.client.kvCollect(pid, durl);
    this.kvTimer = setInterval(() => {
      this.client.kvCollect(pid, durl);
    }, 60000);
  }

  // ==================== 全屏 / 横屏 ====================
  private fsBusy: boolean = false;   // 全屏切换防重入（按钮连点）

  /** 进入全屏：旋转横屏 + 沉浸式（隐藏系统栏 + 状态栏）。按钮与"横屏自动全屏"共用 */
  async enterFullscreen(): Promise<void> {
    if (this.isFullscreen || this.fsBusy) {
      return;
    }
    this.fsBusy = true;
    try {
      const win = await window.getLastWindow(this.ctx);
      this.winObj = win;
      this.originalBrightness = -1;
      // ★ 2026-08-20: 全屏用"横屏受限自动旋转"而非固定 LANDSCAPE：
      //   AUTO_ROTATION_LANDSCAPE_RESTRICTED 忽略系统旋转锁定，且仅在两个横屏方向(90°/270°)
      //   间跟随重力翻转 180° → 手机上下颠倒时画面同步调整，不固定朝一个方向。
      await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_LANDSCAPE);
      await win.setWindowSystemBarEnable([]);
      await win.setWindowLayoutFullScreen(true);
      this.isFullscreen = true;
    } catch (e) {
      console.error('[cctv] 进入全屏失败: ' + (e as Error).message);
    } finally {
      this.fsBusy = false;
    }
  }

  /** 退出全屏：恢复系统默认亮度(-1) + 跟随系统旋转 + 系统栏 + 关闭沉浸式 */
  async exitFullscreen(): Promise<void> {
    if (!this.isFullscreen || this.fsBusy) return;
    this.fsBusy = true;

    try {
      const win = await window.getLastWindow(this.ctx);
      this.winObj = win;

      try { win.setWindowBrightness(-1); } catch (e3) {}
      await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION);
      await win.setWindowSystemBarEnable(['status', 'navigation']);
      try { win.setImmersiveModeEnabledState(false); } catch (e2) {}
      await win.setWindowLayoutFullScreen(false);

      this.isFullscreen = false;
      this.screenLocked = false;

      /* ★ 500ms 后再重算一次（系统栏动画大概率已完成，此时 avoidArea 准确）
      setTimeout(() => {
        this.recalcLayout();
      }, 500); */

    } catch (e) {
      console.error('[exitFullscreen] 退出全屏失败:', e);
    } finally {
      this.fsBusy = false;
    }
  }

  async toggleFullscreen(): Promise<void> {
    if (this.isFullscreen) {
      await this.exitFullscreen();
    } else {
      await this.enterFullscreen();
    }
  }

  // ==================== EPG ====================
  /** ★ 拉取"当前正在播放 + 未来 8 小时"节目单（竖屏下方区域），不足 8 小时跨天拉明天 */
  async fetchUpcomingEpg(pid: string): Promise<void> {
    try {
      const now = new Date();
      const nowMin = now.getHours() * 60 + now.getMinutes();
      const horizonMin = nowMin + 8 * 60;   // 未来 8 小时的绝对分钟（>=1440 即跨天）
      // 拉今天 EPG
      const d = new Date();
      const y = d.getFullYear();
      const m = d.getMonth() + 1;
      const day = d.getDate();
      const date = String(y) + (m < 10 ? '0' + String(m) : String(m)) + (day < 10 ? '0' + String(day) : String(day));
      const r = await getText(this.proxyBase, '/capi/api/yspepg/program/' + pid + '/' + date, {}, 10000);
      let arr: Record<string, Object>[] = [];
      if (r.code === 0) {
        try {
          arr = JSON.parse(r.body) as Record<string, Object>[];
        } catch (e) {
          arr = [];
        }
      }
      // 若跨天，再拉明天 EPG
      let tmrArr: Record<string, Object>[] = [];
      if (horizonMin >= 24 * 60) {
        const t = new Date(d.getTime() + 24 * 60 * 60 * 1000);
        const ty = t.getFullYear();
        const tm = t.getMonth() + 1;
        const td = t.getDate();
        const tdate = String(ty) + (tm < 10 ? '0' + String(tm) : String(tm)) + (td < 10 ? '0' + String(td) : String(td));
        const r2 = await getText(this.proxyBase, '/capi/api/yspepg/program/' + pid + '/' + tdate, {}, 10000);
        if (r2.code === 0) {
          try {
            tmrArr = JSON.parse(r2.body) as Record<string, Object>[];
          } catch (e) {
            tmrArr = [];
          }
        }
      }
      interface AbsItem {
        name: string;
        start: string;
        absStart: number;   // 绝对分钟（今天为 HH:mm 分钟，明天 +1440）
        absEnd: number;
        isCurrent: boolean;
        day: number;
      }
      const all: AbsItem[] = [];
      // 今天
      for (const it of arr) {
        const name = String(it['title'] ?? it['name'] ?? '');
        if (!name) continue;
        const start = fmtEpgTime(String(it['start'] ?? ''));
        const end = fmtEpgTime(String(it['end'] ?? ''));
        let s = parseMin(start);
        let e = parseMin(end);
        if (s < 0 || e < 0) continue;
        if (e <= s) e += 24 * 60;   // 跨凌晨节目
        all.push({ name, start, absStart: s, absEnd: e, isCurrent: false, day: 0 });
      }
      // 明天（绝对分钟 +1440）
      for (const it of tmrArr) {
        const name = String(it['title'] ?? it['name'] ?? '');
        if (!name) continue;
        const start = fmtEpgTime(String(it['start'] ?? ''));
        const end = fmtEpgTime(String(it['end'] ?? ''));
        let s = parseMin(start);
        let e = parseMin(end);
        if (s < 0 || e < 0) continue;
        if (e <= s) e += 24 * 60;
        all.push({ name, start, absStart: s + 24 * 60, absEnd: e + 24 * 60, isCurrent: false, day: 1 });
      }
      // 筛选：正在播放 或 未来 8 小时内开始
      const picked = all.filter((it) => {
        if (it.absStart <= nowMin && nowMin < it.absEnd) return true;         // 正在播放
        if (it.absStart >= nowMin && it.absStart < horizonMin) return true;   // 未来 8h
        return false;
      });
      picked.sort((a, b) => a.absStart - b.absStart);
      // 标记当前节目（isCurrent），其余 future
      let marked = false;
      const items: EpgItem[] = [];
      for (const it of picked) {
        const cur = it.absStart <= nowMin && nowMin < it.absEnd;
        if (cur) {
          items.push({ name: it.name, start: it.start, end: '', isCurrent: true, day: it.day });
          marked = true;
        } else if (it.absStart >= nowMin && it.absStart < horizonMin) {
          items.push({ name: it.name, start: it.start, end: '', isCurrent: false, day: it.day });
        }
      }
      this.upcomingEpg = items;
      // 同步"当前节目条"文案：优先正在播放的节目；未匹配则用第一条（与原 fetchCurrentEpg 一致）
      const curItem = items.find((it) => it.isCurrent);
      if (curItem) {
        this.currentEpg = curItem.name;
      } else if (items.length > 0) {
        this.currentEpg = items[0].name;
      } else {
        this.currentEpg = '';
      }
    } catch (e) {
      console.info('[cctv] 未来节目单拉取失败: ' + (e as Error).message);
    }
  }

  async fetchEpg(pid: string): Promise<void> {
    const d = new Date();
    const y = d.getFullYear();
    const m = d.getMonth() + 1;
    const day = d.getDate();
    const date = String(y) + (m < 10 ? '0' + String(m) : String(m)) + (day < 10 ? '0' + String(day) : String(day));
    this.epgTitle = channelName(pid) + ' 节目单 ' + date;
    this.epgItems = [];
    try {
      // ★ 2026-08-15: 源站正确路径为 capi.yangshipin.cn/api/yspepg/...（含 /api 段）。
      //   此前请求 /capi/yspepg/...（缺 /api）→ 源站 404 → protobuf 为空 → 节目单无数据。
      //   对齐桌面版 C# MainWindow 请求 /capi/api/yspepg/program/{pid}/{date}。
      const r = await getText(this.proxyBase, '/capi/api/yspepg/program/' + pid + '/' + date, {}, 15000);
      if (r.code !== 0) {
        this.epgItems = [{ name: 'EPG 获取失败: ' + r.msg, start: '', end: '', isCurrent: false }];
        this.showEpg = true;
        return;
      }
      const arr = JSON.parse(r.body) as Record<string, Object>[];
      const items: EpgItem[] = [];
      for (const it of arr) {
        // Go 代理 /capi 输出的字段为 title/start/end（对齐桌面版 C#），兼容 name 兜底
        const name = String(it['title'] ?? it['name'] ?? it['programName'] ?? '');
        // 时间统一提取 HH:mm 段（源站格式可能是 "09:30" / "09:30:00" / 完整日期时间）
        const start = fmtEpgTime(String(it['start'] ?? it['startTime'] ?? ''));
        const end = fmtEpgTime(String(it['end'] ?? it['endTime'] ?? ''));
        if (name) {
          // 标记当前正在播放的节目（对齐桌面版 IsCurrent：HH:MM → 分钟比较，处理跨凌晨）
          const isCur = isNowPlaying(start, end);
          items.push({ name: name, start: start, end: end, isCurrent: isCur });
        }
      }
      this.epgItems = items.length > 0 ? items : [{ name: '今日暂无节目单', start: '', end: '', isCurrent: false }];
      this.showEpg = true;
    } catch (e) {
      this.epgItems = [{ name: 'EPG 异常: ' + (e as Error).message, start: '', end: '', isCurrent: false }];
      this.showEpg = true;
    }
  }

  // ==================== UI ====================
  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        // 状态栏（全屏隐藏）
        if (!this.isFullscreen) {
          Row() {
            Circle({ width: 10, height: 10 })
              .fill(this.proxyOk ? '#3ddc84' : '#e53935')
            Text(this.statusText)
              .fontSize(12)
              .fontColor('#b0b0b0')
              .margin({ left: 6 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.loading) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color('#3ddc84')
            }
          }
          // ★ 横屏时宽度与视频一致，竖屏时全宽
          .width(this.isPortrait ? '100%' : (this.videoWidth > 0 ? this.videoWidth : '100%'))
          .height(26)                           // ★ 固定高度
          .padding({ left: 12, right: 12 })      // ★ 只留左右 padding
          .alignItems(VerticalAlign.Center)      // ★ 内容垂直居中
          // ★ 横屏时左侧间隙与视频左对齐
          .margin({ left: (!this.isFullscreen && !this.isPortrait) ? this.sideGap : 0 })
          .alignSelf(ItemAlign.Start)   // 靠左，不要 Column 默认居中
          .backgroundColor('#141414')
        }

        // Web 播放区（全屏时占满；非全屏时浮在顶部，视频内控件叠层）
        Stack({ alignContent: Alignment.Bottom }) {
          Web({ src: NavUrl, controller: this.controller })
            .mixedMode(MixedMode.All)
            .userAgent(Ua)
            .mediaPlayGestureAccess(false)
            .mediaOptions({ resumeInterval: -1, audioExclusive: false ,audioSessionType: 10})
            .javaScriptProxy({
              object: {
                onMsg: this.onMsgProxy
              },
              name: '__nativeBridge',
              methodList: ['onMsg'],
              controller: this.controller
            })
            .onInterceptRequest(this.onIntercept)
            .onPageEnd(this.onPageEnd)
            .onConsole(this.onConsole)
            .width('100%')
            .height(this.isFullscreen ? '100%' : this.videoZoneHeight)
            .backgroundColor('#000000')
            // ★★★ 修复 (2026-08-16 第四次): 用 .hitTestBehavior(HitTestMode.Transparent) 让触摸穿透
            //   SDK 实际 enum 文档 (Sdk\default\openharmony\ets\build-tools\ets-loader\declarations\enums.d.ts):
            //     - Default: 自己+子节点响应, BLOCK 其他节点 (不穿透)
            //     - Block: 自己响应, BLOCK 子节点和其他节点
            //     - Transparent: 自己+子节点响应, ALLOW 其他节点响应 (穿透)
            //     - None: 自己不响应, 子节点响应
            //   Transparent: Web 自己(内部 chromium click)响应 + 允许穿透给原生 Column.onClick
            //   这是本场景的最优选择: chromium click 工作 + 原生 Click 兜底双重保险
            .hitTestBehavior(HitTestMode.None)  // Web 不响应触摸, 让触摸穿透给上层 Column

          // ★★★ 透明触摸接收层 + 全屏手势层 (覆盖整个视频区, 在 Web 之上面板, 触摸事件优先命中)
          Column()
            .width('100%')
            .height(this.isFullscreen ? '100%' : this.videoZoneHeight)
            .backgroundColor('#00000000')
            .onAreaChange((_oldArea: Area, newArea: Area) => {
              // ★ 2026-08-17: 手势区宽度跟随实际渲染; 检测窗口尺寸变化(横竖屏/窗口resize)后重算视频区尺寸
              this.videoZoneWidth = Number(newArea.width);
              this.recalcLayout();
            })
            // ★★★ TapGesture: 触摸视频区域显示控件, 3s 后自动隐藏 (替代 onClick, 跨组件更可靠)
            .gesture(
              TapGesture({ fingers: 1, count: 1 })
              // ★ 锁定时点屏幕仅显示解锁按钮(三按钮已隐藏): 提供解锁入口; 滑动手势仍禁用
                .onAction(() => { this.showControls(); })
            )
            // ★★★ PanGesture: 全屏时上下滑调音量(右半区)/亮度(左半区)
            //   priorityGesture 提高识别优先级: 优先于 TapGesture/onClick/Web 内部触摸被识别,
            //   确保全屏上下滑动调节音量/亮度必定响应 (普通 gesture 可能被点击手势抢占)
            //   ★ 用 event.offsetY 计算位移 (手势累计位移, 不依赖 fingerList, 兼容性更好)
            .priorityGesture(
              PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 8 })
                .onActionStart((event: GestureEvent) => {
                  // ★ 2026-08-17: 锁定时滑动不再静默: 弹出锁(解锁)按钮作为反馈(三按钮已隐藏, 只会显示解锁按钮), 不执行音量/亮度调节
                  if (!this.isFullscreen || this.screenLocked) {
                    if (this.isFullscreen && this.screenLocked) {
                      this.showControls();
                    }
                    this.gestureSide = '';
                    return;
                  }
                  const fullW = this.videoZoneWidth || 1;
                  const finger = event.fingerList && event.fingerList.length > 0 ? event.fingerList[0] : null;
                  // fingerList 异常为空时默认右半区(音量), 避免误判为左半区导致音量调不动
                  const fx = finger ? finger.globalX : fullW;
                  this.gestureSide = (fx > fullW / 2) ? 'vol' : 'bri';
                  // ★ 基准取系统媒体音量(归一化 0~1), 与系统音量条/音量键保持一致
                  this.gestureStartVol = (this.volCur - this.volMin) / Math.max(1, this.volMax - this.volMin);
                  this.gestureStartBri = this.gestureBrightness;
                  this.gestureActive = true;
                  console.info('[gesture] start side=' + this.gestureSide + ' fullW=' + fullW);
                })
                .onActionUpdate((event: GestureEvent) => {
                  // ★ 2026-08-17: 锁定时持续滑动保持锁(解锁)按钮显示反馈, 不调节音量/亮度
                  if (this.screenLocked) { this.showControls(); return; }
                  if (!this.gestureActive || !this.gestureSide) return;
                  const dy = -event.offsetY;  // offsetY 向下为正, 上滑为正
                  const step = dy / 300;      // 300px 滑动 = 1.0 单位
                  if (this.gestureSide === 'vol') {
                    const newV = Math.max(0, Math.min(1, this.gestureStartVol + step));
                    // ★ 音量按 5% 一档步进 (5/10/.../100), 避免逐 1% 微调手感差
                    const snapV = Math.round(newV * 20) / 20;
                    this.volume = snapV;
                    // ★ 调音量自动解除静音（同时切换音频焦点并发模式）
                    this.handleMuteChanged(false);
                    // ★★ 直接设置系统媒体音量 (系统音量条/音量键同步, 与主流视频 App 一致)
                    this.setSysVolumeByRatio(snapV);
                    this.gestureHint = '音量 ' + Math.round(snapV * 100) + '%';
                  } else {
                    const newB = Math.max(0, Math.min(1, this.gestureStartBri + step));
                    this.gestureBrightness = newB;
                    this.gestureHint = '亮度 ' + Math.round(newB * 100) + '%';
                    this.applyBrightness(newB);
                  }
                })
                .onActionEnd(() => {
                  this.gestureActive = false;
                  // 手势结束 800ms 后隐藏提示(期间若再次手势则顺延)
                  if (this.gestureHint !== '') {
                    const hint = this.gestureHint;
                    setTimeout(() => {
                      if (this.gestureHint === hint) { this.gestureHint = ''; }
                    }, 800);
                  }
                  console.info('[gesture] end');
                })
            )

          // 视频内控件（非全屏时也显示，全屏时同样）
          // ★★★ 2026-08-16 第五次重构: 使用 base/media 中 6 个真实 png 图标, 水平基线对齐
          //   图标资源 (entry/src/main/resources/base/media/):
          //     - pause.png / plyay.png       (暂停/播放)
          //     - player_sound_off.png / player_sound_on.png (静音/音量)
          //     - fullscreen.png / window.png  (全屏/退出全屏)
          //   ★ 水平居中一行, 上下垂直居中 (alignItems: VerticalAlign.Center)
          // ★ 2026-08-17: 锁定时隐藏三按钮(暂停/静音/全屏), 仅保留解锁按钮
          if (this.controlsVisible && !this.screenLocked) {
            // ★ 控件遮罩层: 与控件同尺寸(宽=视频宽, 高=64), 半透明底色让图标更清晰可见, 又不遮挡视频
            //   20% 黑色透明度, 点击/滑动穿透 (hitTestBehavior None), 不影响任何手势
            Row()
              .width('100%')
              .height(48)
              .backgroundColor('#33000000')
              .borderRadius(12)
              .position({ x: 0, y: this.isFullscreen ? '80%' : '75%' })
              .hitTestBehavior(HitTestMode.None)

            Row({ space: 18 }) {
              // 左: 暂停/播放 (靠左)
              Image(this.paused ? $r('app.media.plyay') : $r('app.media.pause'))
                .width(48)
                .height(48)
                .objectFit(ImageFit.Contain)
                .onClick(() => {
                  this.evalJs('window.__togglePause && window.__togglePause()')
                    .then((r: string) => { this.paused = r === 'true'; });
                  this.showControls();
                })

              Blank()  // ★ 弹性空间: 暂停靠左, 右侧两控件推向右

              // 中: 静音切换 (靠右, 图标原图偏大调小到 36)
              Image(this.muted ? $r('app.media.player_sound_off') : $r('app.media.player_sound_on'))
                .width(36)
                .height(36)
                .objectFit(ImageFit.Contain)
                .onClick(() => {
                  this.evalJs('window.__toggleMute && window.__toggleMute()')
                    .then((r: string) => {
                      // ★ 问题2 修复: 静音切换时动态调整音频焦点并发模式
                      this.handleMuteChanged(r === 'true');
                    });
                  this.showControls();
                })

              // 右: 全屏切换 (与静音间隔 18, 靠拢)
              Image(this.isFullscreen ? $r('app.media.window') : $r('app.media.fullscreen'))
                .width(48)
                .height(48)
                .objectFit(ImageFit.Contain)
                .onClick(() => {
                  this.showControls();
                  this.toggleFullscreen();
                })
            }
            .width('100%')
            .height(48)                              // ★ 固定高度保证垂直对齐
            // ★ 左右内边距: 5% 靠左, 5% 靠右
            .padding({ left: '5%', right: '5%' })
            .backgroundColor('#00000000')
            .alignItems(VerticalAlign.Center)        // ★ 水平基线对齐
            // ★ 控件位置: 视频底部居中, 非全屏贴视频底, 全屏悬浮视频底
            .position({ x: 0, y: this.isFullscreen ? '80%' : '75%' })
            .onClick(() => { this.showControls(); })
          }

          // ★ 视频区中央友好提示（如"应版权方要求暂停直播"），居中显示，不阻塞操作
          if (this.videoNotice !== '') {
            Text(this.videoNotice)
              .fontSize(15)
              .fontColor('#dddddd')
              .backgroundColor('#b0000000')
              .borderRadius(12)
              .padding({ left: 20, right: 20, top: 14, bottom: 14 })
              .textAlign(TextAlign.Center)
              .position({ x: '50%', y: '45%' })
              .translate({ x: '-50%', y: '-50%' })
              .hitTestBehavior(HitTestMode.None)      // 不拦截触摸，仍可点视频显示控件/切台
          }

          // ★ 手势调节提示(音量/亮度): 手势中显示, 结束后 800ms 自动消失
          if (this.gestureHint !== '') {
            Text(this.gestureHint)
              .fontSize(22)
              .fontColor('#ffffff')
              .backgroundColor('#80000000')
              .borderRadius(10)
              .padding({ left: 18, right: 18, top: 10, bottom: 10 })
              .position({ x: '50%', y: '40%' })
              .translate({ x: '-50%', y: '-50%' })   // 相对自身尺寸居中
              .hitTestBehavior(HitTestMode.None)      // 不拦截触摸
          }

          // ★ 锁屏按钮: 独立浮层, 视频区左侧垂直居中 (x=5% 与暂停按钮同一横坐标, y=50% 视频高度一半), 跟随控件显隐
          //   锁定后仅此按钮显示(unlock 图标), 点击解锁恢复三按钮; 解锁时显示 locked 图标
          //   注意: 不能在 onClick 里直接控制显隐, 父级 Stack.onClick 会冒泡再 showControls;
          //   setTimeout 延迟到冒泡结束后再执行 showControls, 保证最终状态正确
          if (this.controlsVisible && this.isFullscreen) {
            Image(this.screenLocked ? $r('app.media.locked') : $r('app.media.unlock'))
              .width(28)
              .height(28)
              .objectFit(ImageFit.Contain)
              .position({ x: '5%', y: '50%' })
              .translate({ y: '-50%' })               // 自身垂直居中
              .onClick(() => {
                this.screenLocked = !this.screenLocked;
                setTimeout(() => {
                  // ★ 2026-08-17: 锁定后三按钮因 !screenLocked 立即隐藏;
                  //   锁(解锁)按钮不立即关闭: showControls 重置 3s 自动隐藏计时, 延迟自动关闭
                  this.showControls();
                }, 0);
              })
          }

        }
        .width(this.isFullscreen ? '100%' : (this.videoWidth > 0 ? this.videoWidth : '100%'))
        .height(this.isFullscreen ? '100%' : this.videoZoneHeight)
        .margin({
          left: (!this.isFullscreen && !this.isPortrait) ? this.sideGap : 0,
          right: 0                               // ← 不要 channelListW + sideGap
        })
        .alignSelf(ItemAlign.Start)              // ← 靠左，不要 Column 默认居中
        // 保留 Stack.onClick 作为最后兜底（理论上 Column 已覆盖, 但不影响）
        .onClick(() => {
          this.showControls();
        })

        /* ★ 横屏窗口模式：弹性空间将节目条推到底部(紧贴白色条上方)
        if (!this.isFullscreen && !this.isPortrait) {
          Blank()
            .layoutWeight(1)
        } */

        // 当前节目条（全屏隐藏；横屏窗口模式整合到节目单组件头部，不单独显示）
        if (!this.isFullscreen && this.isPortrait) {
          Row() {
            Text(this.currentEpg.length > 0 ? this.currentEpg : '（节目单加载中…）')
              .fontSize(14)
              .fontColor(this.currentEpg ? '#ff3b3b' : '#777777')
              .fontWeight(this.currentEpg ? FontWeight.Bold : FontWeight.Normal)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('节目单 ')
              .fontSize(13)
              .fontColor('#aaaaaa')
            Text('≡')
              .fontSize(16)
              .fontColor('#2f6bff')
              .fontWeight(FontWeight.Bold)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 5, bottom: 5 })
          .backgroundColor('#181818')
          .margin({ left: (!this.isFullscreen && !this.isPortrait) ? this.sideGap : 0,
            right: (!this.isFullscreen && !this.isPortrait) ? (this.sideGap + this.channelListW) : 0 })
          .onClick(() => {
            if (this.currentPid) {
              this.fetchEpg(this.currentPid);
            }
          })
        }

        // ★ 横屏窗口模式：正在播放节目条
        if (!this.isFullscreen && !this.isPortrait) {
          Row() {
            Text(this.currentEpg.length > 0 ? this.currentEpg : '（节目单加载中…）')
              .fontSize(14)
              .fontColor(this.currentEpg ? '#ff3b3b' : '#777777')
              .fontWeight(this.currentEpg ? FontWeight.Bold : FontWeight.Normal)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('节目单 ')
              .fontSize(13)
              .fontColor('#aaaaaa')
            Text('≡')
              .fontSize(16)
              .fontColor('#2f6bff')
              .fontWeight(FontWeight.Bold)
          }
          .width(this.videoWidth)           // 与视频同宽
          .margin({ left: this.sideGap })
          .alignSelf(ItemAlign.Start)
          .padding({ left: 16, right: 16, top: 5, bottom: 5 })
          .backgroundColor('#181818')
          // ★ 精确捕获节目条高度，替换硬编码 38
          .onAreaChange((oldArea: Area, newArea: Area) => {
            const h = newArea.height as number;
            if (h > 0 && Math.abs(h - this.programBarH) > 0.5) {
              this.programBarH = h;
              this.updateVideoSize();
            }
          })
          .onClick(() => {
            if (this.currentPid) {
              this.fetchEpg(this.currentPid);
            }
          })
        }

        // ★ 竖屏：底部区域 — 分组 Tab + 频道列表 + 接下来精彩内容
        if (!this.isFullscreen && this.isPortrait) {
          Column() {
            this.channelTabsAndList()

            // ── 接下来精彩内容（节目单，竖屏显示）──
            Row() {
              Path()
                .commands('M 0,0 L 38,19 L 0,38 Z')  // 高度 38，与 13 号字差不多
                // .width(38)
                // .height(38)
                .fill('#3ddc84')
                .margin({ left: 6, right: 3 })
              Text('接下来精彩内容')
                .fontSize(13)
                .fontColor('#3ddc84')
              Blank()
            }
            .width('100%')
            .backgroundColor(Color.Transparent)
            .alignItems(VerticalAlign.Center)   // 关键：让 Row 内所有元素垂直居中
            if (this.upcomingEpg.length > 0) {
              Scroll() {
                Column({ space: 0 }) {
                  ForEach(this.upcomingEpg, (it: EpgItem, idx: number) => {
                    Row() {
                      Text((it.day === 1 ? '明天 ' : '') + it.start)
                        .fontSize(12)
                        .fontWeight(it.isCurrent ? FontWeight.Bold : FontWeight.Normal)
                        .fontColor(it.isCurrent ? '#ff4444' : '#888888')
                        .width(86)
                      Text(it.name)
                        .fontSize(13)
                        .fontWeight(it.isCurrent ? FontWeight.Bold : FontWeight.Normal)
                        .fontColor(it.isCurrent ? '#ff4444' : '#e0e0e0')
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .width('100%')
                    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
                    .backgroundColor(it.isCurrent ? '#331111' : '#00000000')
                  }, (it: EpgItem, idx: number) => it.start + it.name + String(idx))
                }
                .width('100%')
                .padding({ bottom: 8 })
              }
              .layoutWeight(1)
              .scrollBar(BarState.Off)
              .align(Alignment.Top)   // ★ 2026-08-21: 节目少时内容顶部对齐，不垂直居中
            } else {
              Column() {
                Blank()
                Text('节目单加载中…')
                  .fontSize(12)
                  .fontColor('#666666')
                Blank()
              }
              .layoutWeight(1)
            }
          }
          .width('100%')
          .layoutWeight(1)
          .backgroundColor('#0d0d0d')
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#0a0a0a')
      .padding({ bottom: 0 })

      // ★ 2026-08-22: 横屏窗口模式 — 频道列表在视频右侧（position 叠加在 Stack 内）
      if (!this.isFullscreen && !this.isPortrait) {
        Column() {
          this.channelTabsAndList()
        }
        .width(this.channelListW > 0 ? this.channelListW : '30%')
        .height(this.videoZoneHeight + this.programBarH + this.statusBarH) // 频道高度从顶部开始
        .backgroundColor('#0d0d0d')
        .position({ x: this.winW * 0.65, y: 0 /*this.statusBarH*/ })  // ← 同步调整频道位置
      }

      // EPG 全节目单弹层（点击节目条打开）
      if (this.showEpg) {
        Column() {
          Row() {
            Text(this.epgTitle)
              .fontSize(15)
              .fontColor('#ffffff')
              .layoutWeight(1)
            Button('关闭')
              .fontSize(12)
              .height(28)
              .padding({ left: 10, right: 10 })
              .backgroundColor('#555555')
              .onClick(() => {
                this.showEpg = false;
              })
          }
          .width('100%')
          .padding(12)
          Scroll() {
            Column({ space: 6 }) {
              ForEach(this.epgItems, (it: EpgItem, idx: number) => {
                Row() {
                  Text(it.start)
                    .fontSize(12)
                    .fontColor(it.isCurrent ? '#ff4444' : '#888888')
                    .width(70)
                  Text(it.name)
                    .fontSize(13)
                    .fontWeight(it.isCurrent ? FontWeight.Bold : FontWeight.Normal)
                    .fontColor(it.isCurrent ? '#ff4444' : '#e0e0e0')
                    .layoutWeight(1)
                    .maxLines(2)
                }
                .width('100%')
                .padding({ top: 4, bottom: 4 })
                .backgroundColor(it.isCurrent ? '#3a1a1a' : '#00000000')
                .borderRadius(4)
              }, (it: EpgItem, idx: number) => it.start + it.name + String(idx))
            }
            .width('100%')
            .padding({ left: 12, right: 12, bottom: 16 })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        }
        // ★ 竖屏：屏幕宽度的 88%；横屏：视频区域宽度的 88%
        .width(this.isPortrait ? '88%' : (this.videoWidth > 0 ? this.videoWidth * 0.88 : '88%'))
        .height(this.isPortrait ? '60%' : Math.min(260, this.videoZoneHeight + this.programBarH - 10))
        .backgroundColor('#1e1e1e')
        .borderRadius(12)
        .border({ width: 1, color: '#333333' })
        // ★ 横屏：在视频区域内水平居中（左侧间隙 + 视频宽度的 6% 边距）
        .position(this.isPortrait ? undefined : {
          x: this.sideGap + (this.videoWidth > 0 ? this.videoWidth * 0.06 : 0),
          y: this.statusBarH + 8
        })
        .align(this.isPortrait ? Alignment.Bottom : Alignment.TopStart)
        .margin(this.isPortrait ? { bottom: 70 } : {})
      }
    }
    .width('100%')
    .height('100%')
  }
}