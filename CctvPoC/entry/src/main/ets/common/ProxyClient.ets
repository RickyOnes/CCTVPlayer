/**
 * ProxyClient - 经 Go 代理 (hmos_proxy) 的业务 HTTP 原语
 * 职责：auth / open-token / sign / get-live-info / kvcollect / health + seqid 持久化。
 * 注意：页面内 wasm 签名（__genTokenRnd/__genCKey/__genYspTicket/__generateSignature）由 Index.ets
 * 通过 runJavaScript 调用，本类不接触 Web 组件。
 *
 * Header 对齐桌面版 MainWindow.xaml.cs FetchViaPostMessage：
 *  - auth:         yspappid + seqid + request-id + Cookie(含 nseqId/nrequest-id)
 *                  ★ seqid 单调递增(持久化跨运行不回退)；reqId = 999999+10位随机+13位毫秒时间戳
 *  - open-token:   UA + Referer + Origin + Accept（独立构造）
 *  - get-live-info:SetHdrs + 全部签名头 + Cookie(含 nseqId/nrequest-id)
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { getText, postForm, postJson } from './CctvHttp';
import {
  YspAppId, Guid, VappId, Vsecret, Ua, Cookie, AuthSalt, LiveSaltTc,
  KvBossId, KvPwd, KvUrl, ProxyTimeoutMs
} from './CctvConfig';

export interface AuthResult {
  token: string;
  authTs: string;   // 服务器下发的 ts（秒）
}

export interface LiveInfoResult {
  playUrl: string;
  m3u8: string;
}

/** 按 pid 维度缓存的 auth 条目 */
interface AuthCacheEntry {
  auth: AuthResult;
  /** 写入时间（auth 颁发时刻） */
  time: number;
  /** ★ 最近一次「成功用于 get_live_info」的时间，用于闲置失效判定 */
  lastOk: number;
}

const SEQID_PREF = 'cctv_seqid_pref';
const SEQID_KEY = 'seqId';

/**
 * 需预热的源站域名。2026-08-30 实测：每个新域名首次请求固定 ~2.2s（DNS 冷启动+TCP+TLS），
 * 预热后降到 ~110ms，且 DNS 缓存进程内共享（一次预热，全程受益）。
 *  - player-api / h5access：鉴权链（ArktsProxy 的 TARGET_HOST / OPEN_TOKEN_HOST）
 *  - sapi               ：CMG 解密脚本（1.3MB + 700KB），不预热会让首播多等 ~2.2s
 *  - 三个 CDN           ：m3u8/TS 分片；不预热时切到该 CDN 的频道会多等 ~2.2s
 *                         （实测 CCTV-6 走 mobilelive-play 比其它台慢 2.24s，
 *                          加预热后降到 0.55s；CCTV-9 走 live-dtocnc-cdn）
 *  ★ CDN 域名是逐步发现的（每次 get-live-info 返回的 playurl 可能指向新 CDN），
 *    遇到新的慢频道时，把其 m3u8 的 host 补进这里即可。
 */
const WARM_HOSTS: string[] = [
  'player-api.yangshipin.cn',
  'h5access.yangshipin.cn',
  'sapi.yangshipin.cn',
  'hlslive-tx-cdn.ysp.cctv.cn',
  'mobilelive-play.ysp.cctv.cn',
  'live-dtocnc-cdn.ysp.cctv.cn'
];

export class ProxyClient {
  private base: string;
  private ctx: common.UIAbilityContext;
  private seqId: number = 1;
  private pref: preferences.Preferences | null = null;
  // ★★ 鉴权缓存（2026-08-30 实测定论，两条铁律）：
  //
  // 【铁律1】auth token **按 pid 缓存**。
  //   auth(pid) 把 pid 同时放进 body 和 signature → 服务端签发的 token 绑定该 pid。
  //   用它去拉别的频道 → get_live_info 必返 401。
  //   7/7 全中的实测：pid 不匹配 → 401；同 pid 新 token → 200；
  //   首播之所以成功，只因 preWarmAuth 用的 Channels[0].pid 与首播 pid 相同。
  //   ★ 注意 token 并非一次性：首播复用了预热拿到的 token 且成功。
  //
  // 【铁律2】sessionToken **绝不缓存**（按其性质每次现取）。
  //   DNS 预热后一次 open-token 仅 ~110ms，缓存收益极小而风险高。
  //
  // 按 pid 缓存还有额外收益：切回最近看过的频道可直接命中，省掉 /auth 的 ~180ms。
  private authCache: Map<string, AuthCacheEntry> = new Map<string, AuthCacheEntry>();
  /** 在途的 auth 请求（按 pid），用于去重：避免并发对同一频道重复鉴权 */
  private authInflight: Map<string, Promise<AuthResult>> = new Map<string, Promise<AuthResult>>();
  /** 上次 DNS/连接预热完成时间（0 = 从未预热） */
  private lastWarmDnsAt: number = 0;
  /** 在途预热（去重：并发调用只发一次） */
  private warmDnsInflight: Promise<void> | null = null;
  private static readonly AUTH_CACHE_TTL_MS: number = 5 * 60 * 1000;  // 5分钟绝对有效期

  /**
   * ★★ 双阈值作废（2026-08-30 第十轮实测修正 —— 上一版只按「闲置」是错的）
   *
   * 决定性证据：本轮 20 次换台仅 1 次 401，把三次缓存命中按 **token 年龄** 排队：
   *     年龄 9.8s → OK ／ 年龄 31.4s → OK ／ 年龄 78.3s → 401
   *   而该次 401 的**闲置仅 46.8s**，低于上一版设的 60s 阈值 → 没拦住。
   *   ⇒ 失效由 **token 绝对年龄** 驱动，不是闲置时长。
   *
   * 失败年龄样本（跨两轮）：78.3 / 78.5 / 80.4 / 80.8 / 78.9 / 85.4 / 91.1s …
   * 成功年龄样本：9.8 / 31.4s（以及第九轮两个 ~103s 的反例）
   *   ⇒ 存在随机性，不能用单一阈值精确预测，只能取保守边界。
   *
   * 故同时约束两个维度，任一超限即作废重新鉴权：
   *   - 年龄 > 45s
   *   - 闲置 > 30s
   * 代价评估：一次 /auth 仅 ~56ms（实测缓存命中 677ms vs 重新鉴权 733ms）；
   *  而一次 401 恢复需 ~400ms 且用户能看到卡顿。宁可多花 56ms。
   * 真正的兜底仍是 Index 里「401 → 换新 token 重试一次」（已按 pid 化，不会被吞）。
   */
  private static readonly AUTH_IDLE_STALE_MS: number = 30 * 1000;
  private static readonly AUTH_AGE_STALE_MS: number = 45 * 1000;
  /**
   * ★ 预热「保质期」：超过该时长，源站域名的 DNS 缓存 + keep-alive 连接可能已失效。
   *   2026-08-30 实测：闲置 6 分 38 秒后 /auth 与 /open-token 各重付 ~2.2s 冷握手
   *   （DNS 缓存过期）。取 3 分钟为保守阈值，约一半于失效点，覆盖绝大多数场景。
   *   换台懒预热（warmDnsIfStale）与周期心跳（Index.startWarmHeartbeat）共用此阈值。
   */
  static readonly WARM_STALE_MS: number = 3 * 60 * 1000;

  constructor(ctx: common.UIAbilityContext, base: string) {
    this.ctx = ctx;
    this.base = base;
  }

  /** 检查该 pid 的 auth 缓存是否有效 */
  hasCachedAuth(pid: string): boolean {
    return this.getCachedAuth(pid) !== null;
  }

  /** 获取该 pid 的 auth 缓存；无效返回 null */
  getCachedAuth(pid: string): AuthResult | null {
    const e: AuthCacheEntry | undefined = this.authCache.get(pid);
    if (e === undefined) {
      return null;
    }
    const now = Date.now();
    // ① 绝对有效期（5 分钟，兜底）
    if ((now - e.time) >= ProxyClient.AUTH_CACHE_TTL_MS) {
      this.authCache.delete(pid);
      return null;
    }
    // ② token 年龄超限 → 服务端大概率已判废
    if ((now - e.time) >= ProxyClient.AUTH_AGE_STALE_MS) {
      this.authCache.delete(pid);
      return null;
    }
    // ③ 闲置过久
    if ((now - e.lastOk) >= ProxyClient.AUTH_IDLE_STALE_MS) {
      this.authCache.delete(pid);
      return null;
    }
    return e.auth;
  }

  /** 写入该 pid 的 auth 缓存（不含 sessionToken） */
  setCachedAuth(pid: string, auth: AuthResult): void {
    this.authCache.set(pid, { auth: auth, time: Date.now(), lastOk: Date.now() } as AuthCacheEntry);
    console.info('[proxy] auth 缓存已更新 pid=' + pid + '，有效期 5 分钟');
  }

  /**
   * ★ 标记该 pid 的 token「刚刚成功用过一次」，刷新闲置计时。
   *   应在 get_live_info 成功后调用。
   */
  markAuthUsed(pid: string): void {
    const e: AuthCacheEntry | undefined = this.authCache.get(pid);
    if (e !== undefined) {
      e.lastOk = Date.now();
      this.authCache.set(pid, e);
    }
  }

  /** 清除鉴权缓存：传 pid 清该频道，不传清空全部 */
  clearCachedAuth(pid?: string): void {
    if (pid === undefined) {
      this.authCache.clear();
      return;
    }
    this.authCache.delete(pid);
  }

  /**
   * ★ 取该 pid 的 auth，带「在途请求去重」，写入缓存由本方法负责。
   *
   * 2026-08-30 实测（19:08 那轮）：冷启动时 preWarmAuth 与首播 playChannel 会
   * 并发发起同一 pid 的 /auth（00.775 与 01.597 两条），各自都付一次 DNS 冷启动
   * ~2.2s，后发的那条还要晚 0.8s 才完成 → 首播白等约 0.87s。
   * 去重后后到者直接复用先到者的 Promise：
   *   等待 00.775 那条（02.957 完成）而非 01.597 那条（03.83 完成）。
   * 附带收益：快速连点同一频道时不会重复鉴权，降低触发源站频控的风险。
   */
  async ensureAuth(pid: string): Promise<AuthResult> {
    const cached: AuthResult | null = this.getCachedAuth(pid);
    if (cached !== null) {
      console.info('[proxy] 命中 auth 缓存 pid=' + pid + '（跳过 /auth 网络请求）');
      return cached;
    }
    const inflight: Promise<AuthResult> | undefined = this.authInflight.get(pid);
    if (inflight !== undefined) {
      console.info('[proxy] 复用在途 auth pid=' + pid);
      return inflight;
    }
    const p: Promise<AuthResult> = this.auth(pid).then((a: AuthResult) => {
      this.setCachedAuth(pid, a);
      this.authInflight.delete(pid);
      return a;
    }).catch((e: Error) => {
      this.authInflight.delete(pid);
      throw e;
    });
    this.authInflight.set(pid, p);
    return p;
  }

  /**
   * ★ DNS / 连接预热：对源站域名各发一次轻量请求，结果忽略。
   *   2026-08-30 实测：每个新域名首次请求固定 ~2.2s（DNS 冷启动 + TCP + TLS），
   *   预热后同域名请求降到 ~110ms（get-live-info 实测 113ms）。
   *   启动时并行预热，可把首播的两次握手从串行 4.4s 压到并行 ~2.2s；
   *   也是「sessionToken 改为每次现取」的前提（否则换台要多付 2.2s）。
   */
  async warmDns(): Promise<void> {
    if (this.warmDnsInflight !== null) {
      return this.warmDnsInflight;
    }
    const p: Promise<void> = this.doWarmDns();
    this.warmDnsInflight = p;
    try {
      await p;
    } finally {
      this.warmDnsInflight = null;
    }
  }

  private async doWarmDns(): Promise<void> {
    const jobs: Promise<void>[] = [];
    for (const host of WARM_HOSTS) {
      jobs.push(
        getText('https://' + host, '/', { 'User-Agent': Ua }, 5000).then(() => {
          console.info('[warmDns] ' + host + ' 预热完成');
        }).catch(() => {
          // 预热失败不影响主流程
        })
      );
    }
    await Promise.all(jobs);
    this.lastWarmDnsAt = Date.now();
  }

  /**
   * ★ fire-and-forget 预热：距上次预热超过 thresholdMs 才补一次，不阻塞调用方、结果忽略。
   *   供「换台懒预热」与「周期心跳」共用：任一先触发都会刷新 lastWarmDnsAt，
   *   另一方在阈值内不会重复预热。
   */
  warmDnsIfStale(thresholdMs: number): void {
    if (this.warmDnsInflight !== null) {
      return;  // 已有预热在途
    }
    if (Date.now() - this.lastWarmDnsAt < thresholdMs) {
      return;  // 近期预热过
    }
    this.warmDns().catch(() => {
    });
  }

  getBase(): string {
    return this.base;
  }

  /** 启动时加载持久化 seqid，防服务器 20401 拒绝 */
  async init(): Promise<void> {
    // ★ seqid 是服务端按 guid 校验的单调计数器，绝不回退。
    //   桌面版（同 guid）已把 seqid 推到 43+，若鸿蒙版从 1 开始会被判"回退"→ 20401。
    //   故初始值抬高到 10000，确保高于服务器已记录值，之后本地持久化继续递增。
    const SEQID_FLOOR = 10000;
    try {
      this.pref = await preferences.getPreferences(this.ctx, { name: SEQID_PREF });
      const v = Number(this.pref.getSync(SEQID_KEY, 0));
      this.seqId = (isNaN(v) || v < SEQID_FLOOR) ? SEQID_FLOOR : v;
    } catch (e) {
      this.seqId = SEQID_FLOOR;
    }
  }

  private async persistSeqId(): Promise<void> {
    try {
      if (this.pref) {
        await this.pref.put(SEQID_KEY, this.seqId);
        await this.pref.flush();
      }
    } catch (e) {
      // 忽略持久化失败
    }
  }

  async nextSeqId(): Promise<number> {
    this.seqId += 1;
    await this.persistSeqId();
    return this.seqId;
  }

  static genRandStr(len: number): string {
    // ★ 对齐桌面版 CctvApiClient.RandStr：62 字符集（a-z A-Z 0-9）。rand_str 必须含大写，
    //   全小写会被源站判 "RandStr有误"(code 10014)
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    let s = '';
    for (let i = 0; i < len; i++) {
      s += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return s;
  }

  /** yyyy-MM-dd HH:mm:ss 本地时间 */
  static fmtNow(): string {
    const d = new Date();
    const pad = (n: number): string => n < 10 ? '0' + String(n) : String(n);
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
      ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
  }

  /** 标准浏览器头（对齐 SetHdrs） */
  static stdHeaders(): Record<string, string> {
    return {
      'User-Agent': Ua,
      'Referer': 'https://yangshipin.cn/',
      'Origin': 'https://yangshipin.cn',
      'accept': 'application/json, text/plain, */*',
      'accept-language': 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7,en-GB;q=0.6',
      'cache-control': 'no-cache',
      'pragma': 'no-cache',
      'priority': 'u=1, i'
    };
  }

  /** GET {base}/health 探测代理存活 */
  async health(): Promise<boolean> {
    const r = await getText(this.base, '/health', {}, 3000);
    return r.code === 0 && r.status === 200;
  }

  /** POST {base}/sign 计算 4 类 MD5 签名之一 */
  async sign(kind: string, fields: Record<string, string>, salt: string): Promise<string> {
    const payload = JSON.stringify({ kind: kind, fields: fields, salt: salt });
    const h: Record<string, string> = { 'Content-Type': 'application/json' };
    const r = await postJson(this.base, '/sign', payload, h, ProxyTimeoutMs);
    if (r.code !== 0) {
      throw new Error('sign failed: ' + r.msg);
    }
    try {
      const obj = JSON.parse(r.body) as Record<string, string>;
      const sig = obj['sig'];
      if (typeof sig === 'string' && sig.length === 32) {
        return sig;
      }
    } catch (e) {
      // fallthrough
    }
    throw new Error('sign bad response: ' + r.body.slice(0, 80));
  }

  signAuth(pid: string, randStr: string): Promise<string> {
    const fields: Record<string, string> = {
      'appid': 'ysp_pc',
      'guid': Guid,
      'pid': pid,
      'rand_str': randStr
    };
    return this.sign('auth', fields, AuthSalt);
  }

  signSdkInput(fields: Record<string, string>): Promise<string> {
    return this.sign('sdkInput', fields, LiveSaltTc);
  }

  /**
   * body.signature：与 sdkInput 同源字段字典（Ordinal 排序，排除 signature，加 LiveSaltTc）。
   * 注意：C# 版 ComputeLiveBodySignature 用业务字段（含 rand_str），Go /sign 契约一致。
   */
  signBody(fields: Record<string, string>): Promise<string> {
    return this.sign('bodySig', fields, LiveSaltTc);
  }

  /**
   * POST {base}/auth 获取 token + authTs
   * ★ 对齐桌面版 MainWindow.xaml.cs FetchViaPostMessage：
   *   - 必须带 Cookie + seqid + request-id（缺 seqid/request-id → 源站 "RandStr有误" 10014）
   *   - seqid 单调递增（持久化）；reqId = 999999 + 10位随机 + 13位毫秒时间戳
   */
  async auth(pid: string): Promise<AuthResult> {
    const randStr = ProxyClient.genRandStr(10);   // 62 字符集，真实浏览器 auth rand_str 是独立随机 10 位
    const signature = await this.signAuth(pid, randStr);

    const seqId = await this.nextSeqId();
    const ts = Date.now().toString();
    const reqId = '999999' + ProxyClient.genRandStr(10) + ts;

    const fields: Record<string, string> = {
      'pid': pid,
      'guid': Guid,
      'appid': 'ysp_pc',
      'rand_str': randStr,
      'signature': signature
    };
    // ★ auth 头精简为与桌面版 MainWindow.xaml.cs(513-525) 完全一致：
    //   yspappid + seqid + request-id + UA + Accept-Language + Cookie(含 nseqId/nrequest-id)
    const headers: Record<string, string> = {
      'User-Agent': Ua,
      'Accept-Language': 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7'
    };
    headers['yspappid'] = YspAppId;
    headers['seqid'] = String(seqId);
    headers['request-id'] = reqId;
    headers['Cookie'] = Cookie + ' nseqId=' + String(seqId) + '; nrequest-id=' + reqId;

    const r = await postForm(this.base, '/auth', fields, headers, ProxyTimeoutMs);
    if (r.code !== 0) {
      throw new Error('auth http ' + r.status + ' ' + r.msg);
    }
    const obj = JSON.parse(r.body) as Record<string, Object>;
    const data = (obj['data'] ?? {}) as Record<string, Object>;
    const token = data['token'] as string;
    const authTs = String(data['ts'] ?? '');
    if (!token) {
      throw new Error('auth no token: ' + r.body.slice(0, 160));
    }
    return { token: token, authTs: authTs };
  }

  /** GET {base}/open-token 换 sessionToken（UA+Referer+Origin+Accept 独立头） */
  async openToken(token: string, authTs: string, tokenRnd: string): Promise<string> {
    const ts = Date.now().toString();
    const q = 'yspappid=' + encodeURIComponent(YspAppId) +
      '&guid=' + encodeURIComponent(Guid) +
      '&vappid=' + encodeURIComponent(VappId) +
      '&vsecret=' + encodeURIComponent(Vsecret) +
      '&raw=1&version=v1' +
      '&ts=' + encodeURIComponent(ts) +
      '&rnd=' + encodeURIComponent(tokenRnd);
    const headers: Record<string, string> = {
      'User-Agent': Ua,
      'Referer': 'https://yangshipin.cn/',
      'Origin': 'https://yangshipin.cn',
      'Accept': '*/*'
    };
    const r = await getText(this.base, '/open-token?' + q, headers, ProxyTimeoutMs);
    if (r.code !== 0) {
      throw new Error('open-token http ' + r.status + ' ' + r.msg);
    }
    const obj = JSON.parse(r.body) as Record<string, Object>;
    const data = (obj['data'] ?? {}) as Record<string, Object>;
    const sessionToken = data['token'] as string;
    if (!sessionToken) {
      throw new Error('open-token no token: ' + r.body.slice(0, 160));
    }
    return sessionToken;
  }

  /** POST {base}/get-live-info 获取 m3u8（完整签名 headers；reqId2/seqId2 由调用方传入，保证 yspsdksign 一致） */
  async getLiveInfo(
    bodyJson: string,
    token: string,
    yspSdkInput: string,
    yspSdkSign: string,
    yspTicket: string,
    reqId2: string,
    seqId2: number
  ): Promise<LiveInfoResult> {
    const headers: Record<string, string> = ProxyClient.stdHeaders();
    headers['yspappid'] = YspAppId;
    headers['yspplayertoken'] = token;
    headers['yspsdkinput'] = yspSdkInput;
    headers['yspsdksign'] = yspSdkSign;
    headers['yspticket'] = yspTicket;
    headers['request-id'] = reqId2;
    headers['seqid'] = String(seqId2);
    headers['Cookie'] = Cookie + ' nseqId=' + String(seqId2) + '; nrequest-id=' + reqId2;

    const r = await postJson(this.base, '/get-live-info', bodyJson, headers, ProxyTimeoutMs);
    if (r.code !== 0) {
      throw new Error('get-live-info http ' + r.status + ' ' + r.msg);
    }
    const obj = JSON.parse(r.body) as Record<string, Object>;
    const data = (obj['data'] ?? {}) as Record<string, Object>;
    const playUrl = (data['playurl'] as string) ?? (data['vurl'] as string);
    const extended = (data['extended_param'] as string) ?? '';
    if (!playUrl) {
      throw new Error('get-live-info no playurl: ' + r.body.slice(0, 200));
    }
    return { playUrl: playUrl, m3u8: playUrl + extended };
  }

  /** kvcollect 心跳（直连官方域名，失败忽略，不影响播放） */
  async kvCollect(livePid: string, durl: string): Promise<void> {
    try {
      const ftime = ProxyClient.fmtNow();
      const rand = ProxyClient.genRandStr(10);
      const fields: Record<string, string> = {
        'BossId': KvBossId,
        'Pwd': KvPwd,
        'ftime': ftime,
        'progid': livePid,
        'viewid': livePid,
        'livepid': livePid,
        'durl': durl,
        'fplayerver': '189',
        'platform': '5910204',
        'appver': '1.1.11',
        'guid': Guid,
        'devtype': Ua,
        'switch': 'fhd',
        'defn': 'fhd',
        'cmd': '263',
        'iqq': '',
        'nettype': '4g',
        'url': durl,
        'rand_str': rand
      };
      const sig = await this.sign('kv', fields, AuthSalt);
      fields['signature'] = sig;
      const payload = JSON.stringify(fields);
      const h: Record<string, string> = {
        'Content-Type': 'application/json',
        'Referer': 'https://yangshipin.cn/',
        'User-Agent': Ua,
        'Origin': 'https://yangshipin.cn'
      };
      const r = await postJson('https://aatc-api.yangshipin.cn', '/kvcollect?bossid=' + KvBossId + '&pwd=' + KvPwd,
        payload, h, 8000);
      // 心跳失败忽略
    } catch (e) {
      // 心跳失败忽略
    }
  }
}
