import { socket } from '@kit.NetworkKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { computeSign, SignKind } from './ProxySigner';
import { decodeEpgProtobuf } from './ProxyEpg';
import { injectSapiAsset, SAPI_INJECT_VER } from './CmgInject';

/** 本地 sapi 注入缓存路径（与 RawfileDeploy.buildSapiCache 保持一致） */
function sapiCachePath(resDir: string, fileName: string): string {
  return resDir + '/sapi_cache/inj_' + SAPI_INJECT_VER + '_' + fileName;
}

/** 构造 /sapi 响应 */
function sapiResp(code: number, body: string): ProxyResponse {
  const r = new ProxyResponse();
  r.code = code;
  r.headers.set('Content-Type', 'application/javascript; charset=utf-8');
  r.headers.set('Access-Control-Allow-Origin', '*');
  r.headers.set('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0');
  r.headers.set('Pragma', 'no-cache');
  r.body = body;
  return r;
}

/** 写本地 sapi 注入缓存（失败忽略：最坏情况只是下次仍走网络） */
function writeSapiCache(path: string, text: string): void {
  try {
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, stringToBytes(text).buffer as ArrayBuffer);
    } finally {
      fs.closeSync(file);
    }
    console.info(`[ArktsProxy] /sapi 缓存已写入 ${path}`);
  } catch (e) {
    console.error(`[ArktsProxy] /sapi 缓存写入失败: ${(e as Error).message}`);
  }
}

/**
 * ArktsProxy - 手机本机 HTTP 代理（ArkTS 重写版，替代 Go 的 libhmos_proxy.so）。
 *
 * 用 TCPSocketServer 监听 127.0.0.1:18888，手动解析 HTTP 请求，路由到源站（@ohos.net.http），
 * 手动构造 HTTP 响应回写。功能与 hmos/proxy/main.go 对齐。
 */

const LISTEN_PORT = 18888;
const TARGET_HOST = 'player-api.yangshipin.cn';
const OPEN_TOKEN_HOST = 'h5access.yangshipin.cn';
const CAPI_HOST = 'capi.yangshipin.cn';
const SAPI_HOST = 'sapi.yangshipin.cn';
const CHROME_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36';

/** 解析后的 HTTP 请求 */
class ParsedRequest {
  method: string = '';
  path: string = '';
  query: string = '';
  headers: Map<string, string> = new Map<string, string>();
  body: string = '';
}

/** 二进制响应 */
class BinaryResp {
  code: number = 0;
  body: Uint8Array = new Uint8Array(0);
  contentType: string = '';
}

/** 代理响应 */
class ProxyResponse {
  code: number = 0;
  headers: Map<string, string> = new Map<string, string>();
  body: string = '';
  binary: Uint8Array = new Uint8Array(0);
  isBinary: boolean = false;
}

export type ProxyStatusCb = (ok: boolean, detail: string) => void;

export class ArktsProxy {
  private server: socket.TCPSocketServer | null = null;
  private running = false;
  private resDir: string = '';

  /** 启动本地 HTTP 代理（监听 127.0.0.1:18888）。resDir 为 rawfile 部署后的资源根目录。 */
  async start(resDir: string, cb: ProxyStatusCb): Promise<void> {
    this.resDir = resDir;
    if (this.running) {
      cb(true, 'already running');
      return;
    }
    try {
      this.server = socket.constructTCPSocketServerInstance();
      const addr: socket.NetAddress = { address: '127.0.0.1', port: LISTEN_PORT } as socket.NetAddress;
      this.server.on('connect', (conn: socket.TCPSocketConnection) => {
        this.handleConnection(conn);
      });
      this.server.on('error', (e: BusinessError) => {
        console.error(`[ArktsProxy] server error: ${e.message}`);
      });
      await this.server.listen(addr);
      this.running = true;
      console.info(`[ArktsProxy] listening on 127.0.0.1:${LISTEN_PORT}`);
      cb(true, 'ok');
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[ArktsProxy] listen failed code=${err.code} msg=${err.message}`);
      cb(false, `listen failed: ${err.message}`);
    }
  }

  /** 停止代理 */
  async stop(): Promise<void> {
    if (this.server && this.running) {
      try {
        await this.server.close();
      } catch (e) {
        // ignore
      }
      this.server = null;
      this.running = false;
    }
  }

  /** 处理单个客户端连接：读请求 → 路由 → 写响应 */
  private handleConnection(conn: socket.TCPSocketConnection): void {
    let buf = '';
    let handling = false;   // ★ 当前连接上已有一个请求在处理（响应后会 close，不再接新请求）
    conn.on('message', (info: socket.SocketMessageInfo) => {
      const chunk = arrayBufferToString(info.message);
      buf += chunk;
      if (handling) {
        return;
      }
      const headerEnd = buf.indexOf('\r\n\r\n');
      if (headerEnd < 0) {
        return;
      }
      // ★★ 必须按 Content-Length 等 body 收全再路由：
      //    TCP 分段时 headers 与 body 常不在同一个 chunk。只看 \r\n\r\n 会拿到残缺 body：
      //      /sign、/get-live-info 的 JSON 解析失败 → 源站 400/401；
      //      Content-Length 大于实际收到的字节时，curl 会一直等到 readTimeout(10s) 才返回。
      //    实测 2026-08-30 首次换台的 get-live-info 挂起 ~10s 即由此引起。
      const bodyStart = headerEnd + 4;
      const need = parseContentLength(buf.substring(0, headerEnd));
      if (buf.length - bodyStart < need) {
        return;   // body 未收全，等下一个 chunk
      }
      handling = true;
      const req = parseHttpRequest(buf);
      buf = '';   // 消费后清空，避免残留拼接到后续请求
      console.info(`[ArktsProxy] RECV ${req.method} ${req.path}`);
      if (req.method === '') {
        this.sendResponse(conn, 400, new Map<string, string>(), 'Bad Request', new Uint8Array(0));
        return;
      }
      this.route(req).then((resp: ProxyResponse) => {
        this.sendResponse(conn, resp.code, resp.headers, resp.body, resp.isBinary ? resp.binary : new Uint8Array(0));
      }).catch((e: Error) => {
        this.sendResponse(conn, 502, new Map<string, string>(), `{"code":-1,"msg":"${e.message}"}`, new Uint8Array(0));
      });
    });
    conn.on('error', (e: BusinessError) => {
      console.error(`[ArktsProxy] conn error: ${e.message}`);
    });
  }

  /** 路由分发 */
  private async route(req: ParsedRequest): Promise<ProxyResponse> {
    const p = req.path;
    if (p === '/health') {
      const r = new ProxyResponse();
      r.code = 200;
      r.headers.set('Content-Type', 'text/plain');
      r.body = 'OK';
      return r;
    }
    if (p === '/sign') {
      return this.handleSign(req);
    }
    if (p.startsWith('/capi/')) {
      return this.handleCapi(req);
    }
    if (p.startsWith('/sapi/')) {
      return this.handleSapi(req);
    }
    if (p.startsWith('/media/')) {
      return this.handleMediaPath(req);
    }
    // 兼容旧格式（可保留一段时间）
    if (p === '/media') {
      return this.handleMedia(req);
    }
    if (p === '/open-token') {
      return this.handleOpenToken(req);
    }
    if (p === '/player') {
      return this.handlePlayer();
    }
    if (p === '/Library/CMGPlayer.json') {
      return this.handleCmgPlayerJson();
    }
    if (p === '/auth' || p === '/get-live-info') {
      return this.handlePlayerApi(req, p);
    }
    const r = new ProxyResponse();
    r.code = 404;
    r.headers.set('Access-Control-Allow-Origin', '*');
    r.body = 'unknown path';
    return r;
  }

  /** /sign：4 类 MD5 签名 */
  private handleSign(req: ParsedRequest): ProxyResponse {
    const r = new ProxyResponse();
    try {
      const parsed = JSON.parse(req.body) as SignReq;
      const sig = computeSign(parsed.kind as SignKind, parsed.fields);
      r.code = 200;
      r.headers.set('Content-Type', 'application/json; charset=utf-8');
      // ★ 必须用字符串字面量 key：属性混淆只改标识符形式的属性名，不改 'sig' 这种字符串 key。
      //   ProxyClient.sign 侧是 obj['sig'] 下标读取（同样不参与混淆），两端必须都是字面量 sig，
      //   否则开启 -enable-property-obfuscation 后 /sign 响应永远解析不到 sig。
      r.body = JSON.stringify({ 'sig': sig });
    } catch (e) {
      r.code = 400;
      r.body = (e as Error).message;
    }
    return r;
  }

  /** /capi：EPG protobuf → JSON */
  private async handleCapi(req: ParsedRequest): Promise<ProxyResponse> {
    const rest = req.path.substring(5);
    const url = 'https://' + CAPI_HOST + rest + (req.query ? '?' + req.query : '');
    const hdrs = new Map<string, string>();
    hdrs.set('User-Agent', CHROME_UA);
    hdrs.set('Referer', 'https://yangshipin.cn/');
    hdrs.set('Origin', 'https://yangshipin.cn');
    hdrs.set('Accept', 'application/json, text/plain, */*');
    const resp = await httpGetBinary(url, hdrs);
    const json = decodeEpgProtobuf(resp.body);
    const r = new ProxyResponse();
    r.code = 200;
    r.headers.set('Content-Type', 'application/json; charset=utf-8');
    r.headers.set('Access-Control-Allow-Origin', '*');
    r.body = json;
    return r;
  }

  /**
   * /sapi：CMG 脚本（对齐 Go main.go 的 /sapi 处理器）
   *
   * ★★ 冷启动优化（2026-08-30）：这块原先占冷启动 4.16s 中的 2.44s（59%），
   *   因为它位于关键路径最前端：wasm 编译依赖 cmg.worker.js，首播又依赖 wasm。
   *   改为「本地注入缓存优先」：
   *     ① 命中 inj_{ver}_{name}（部署期已注入 + 锚点校验）→ 直接返回，~10ms
   *     ② 未命中 → 走网络 + 注入；**仅当锚点全部命中**才写缓存（写坏=永久绿屏）
   *   ★ 安全不变量：ok=false 时既不缓存也不返回注入产物，行为退化为「网络直出」，
   *     与优化前等价，不会引入新的失败模式。
   */
  private async handleSapi(req: ParsedRequest): Promise<ProxyResponse> {
    const rest = req.path.substring(5);
    const fileName: string = rest.substring(rest.lastIndexOf('/') + 1);
    const cachePath: string = sapiCachePath(this.resDir, fileName);

    // ① 本地注入缓存（快路径）
    try {
      const cached = readFileString(cachePath);
      if (cached.length > 0) {
        console.info(`[ArktsProxy] /sapi 缓存命中 ${fileName} (${cached.length} bytes)`);
        return sapiResp(200, cached);
      }
    } catch (e) {
      // 缓存不存在或读取失败 → 走网络
    }

    // ② 网络拉取 + 注入
    const url = 'https://' + SAPI_HOST + rest + (req.query ? '?' + req.query : '');
    const hdrs = new Map<string, string>();
    hdrs.set('User-Agent', CHROME_UA);
    hdrs.set('Referer', 'https://yangshipin.cn/');
    hdrs.set('Origin', 'https://yangshipin.cn');
    hdrs.set('Accept', '*/*');
    const resp = await httpGetBinary(url, hdrs);
    const raw = bytesToString(resp.body);
    const injected = injectSapiAsset(fileName, raw, LISTEN_PORT);
    console.info(`[ArktsProxy] /sapi 网络注入 ${fileName}: ${injected.detail} ok=${injected.ok}`);

    // ★ 只有全部锚点命中才允许落盘；否则保持每次走网络（与优化前行为一致）
    if (injected.ok && injected.text.length > 0) {
      writeSapiCache(cachePath, injected.text);
    }
    return sapiResp(resp.code, injected.text);
  }

  /** /media：任意 CDN URL 转发（m3u8/TS/key） */
  private async handleMedia(req: ParsedRequest): Promise<ProxyResponse> {
    let target = '';
    const m = req.query.match(/(?:^|&)u=([^&]*)/);
    if (m) {
      target = decodeURIComponent(m[1]);
    }
    if (!target) {
      const r = new ProxyResponse();
      r.code = 400;
      r.headers.set('Access-Control-Allow-Origin', '*');
      r.body = 'missing u';
      return r;
    }
    const hdrs = new Map<string, string>();
    hdrs.set('User-Agent', CHROME_UA);
    hdrs.set('Referer', 'https://yangshipin.cn/');
    hdrs.set('Origin', 'https://yangshipin.cn');
    const resp = await httpGetBinary(target, hdrs);
    const r = new ProxyResponse();
    r.headers.set('Access-Control-Allow-Origin', '*');
    r.code = resp.code;
    const ct = resp.contentType;
    const bodyText = bytesToString(resp.body);
    const isM3u8 = ct.includes('mpegurl') || ct.includes('vnd.apple') ||
                 target.endsWith('.m3u8') || target.includes('.m3u8') ||
                 /^#EXTM3U/i.test(bodyText.substring(0, 10));
    if (isM3u8) {
      const proxyPrefix = 'http://127.0.0.1:' + LISTEN_PORT + '/media/';
      const text = rewriteM3U8(bodyText, target, proxyPrefix);
      r.headers.set('Content-Type', ct !== '' ? ct : 'application/vnd.apple.mpegurl');
      r.body = text;
      r.isBinary = false;
    } else {
      r.headers.set('Content-Type', ct !== '' ? ct : 'application/octet-stream');
      r.binary = resp.body;
      r.isBinary = true;
    }
    return r;
  }

  /** /media/<base64/percent-url>：将路径编码到 URL path 中，避免长 URL 被 403/截断 */
  private async handleMediaPath(req: ParsedRequest): Promise<ProxyResponse> {
    const p = req.path;
    let raw = '';
    if (p.length > '/media/'.length) {
      raw = decodeURIComponent(p.substring('/media/'.length));
    }
    let target = raw;
    const q = req.query;
    if (q) {
      target += (target.indexOf('?') < 0 ? '?' : '&') + q;
    }
    if (!target) {
      const r = new ProxyResponse();
      r.code = 400;
      r.headers.set('Access-Control-Allow-Origin', '*');
      r.body = 'missing u';
      return r;
    }
    const hdrs = new Map<string, string>();
    hdrs.set('User-Agent', CHROME_UA);
    hdrs.set('Referer', 'https://yangshipin.cn/');
    hdrs.set('Origin', 'https://yangshipin.cn');
    const resp = await httpGetBinary(target, hdrs);
    const r = new ProxyResponse();
    r.headers.set('Access-Control-Allow-Origin', '*');
    r.code = resp.code;
    const ct = resp.contentType;
    const bodyText = bytesToString(resp.body);
    const isM3u8 = ct.includes('mpegurl') || ct.includes('vnd.apple') ||
                 target.endsWith('.m3u8') || target.includes('.m3u8') ||
                 /^#EXTM3U/i.test(bodyText.substring(0, 10));
    if (isM3u8) {
      const proxyPrefix = 'http://127.0.0.1:' + LISTEN_PORT + '/media/';
      const text = rewriteM3U8(bodyText, target, proxyPrefix);
      r.headers.set('Content-Type', ct !== '' ? ct : 'application/vnd.apple.mpegurl');
      r.body = text;
      r.isBinary = false;
    } else {
      r.headers.set('Content-Type', ct !== '' ? ct : 'application/octet-stream');
      r.binary = resp.body;
      r.isBinary = true;
    }
    return r;
  }

  /** /auth /get-live-info：POST 到 player-api */
  private async handlePlayerApi(req: ParsedRequest, path: string): Promise<ProxyResponse> {
    const apiPath = path === '/auth' ? '/v1/player/auth' : '/v1/player/get_live_info';
    const url = 'https://' + TARGET_HOST + apiPath;
    const hdrs = new Map<string, string>();
    hdrs.set('User-Agent', CHROME_UA);
    hdrs.set('Referer', 'https://yangshipin.cn/');
    hdrs.set('Origin', 'https://yangshipin.cn');
    hdrs.set('Accept', 'application/json, text/plain, */*');
    hdrs.set('Accept-Language', 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7');
    hdrs.set('Cache-Control', 'no-cache');
    hdrs.set('Pragma', 'no-cache');
    hdrs.set('Content-Type', path === '/auth'
      ? 'application/x-www-form-urlencoded;charset=UTF-8'
      : 'application/json;charset=UTF-8');
    const passHeaders = ['yspappid', 'yspplayertoken', 'yspsdkinput', 'yspsdksign', 'yspticket', 'request-id', 'seqid', 'Cookie'];
    for (const h of passHeaders) {
      const v = req.headers.get(h.toLowerCase());
      if (v && v !== '') {
        hdrs.set(h, v);
      }
    }
    const resp = await httpPost(url, req.body, hdrs);
    const r = new ProxyResponse();
    r.code = resp.code;
    r.headers.set('Content-Type', 'application/json; charset=utf-8');
    r.headers.set('Access-Control-Allow-Origin', '*');
    r.body = bytesToString(resp.body);
    return r;
  }

  /** /open-token：GET h5access */
  private async handleOpenToken(req: ParsedRequest): Promise<ProxyResponse> {
    const url = 'https://' + OPEN_TOKEN_HOST + '/web/open/token' + (req.query ? '?' + req.query : '');
    const hdrs = new Map<string, string>();
    hdrs.set('User-Agent', CHROME_UA);
    hdrs.set('Referer', 'https://yangshipin.cn/');
    hdrs.set('Origin', 'https://yangshipin.cn');
    hdrs.set('Accept', 'application/json, text/plain, */*');
    const resp = await httpGetBinary(url, hdrs);
    const r = new ProxyResponse();
    r.code = resp.code;
    r.headers.set('Content-Type', 'application/json; charset=utf-8');
    r.headers.set('Access-Control-Allow-Origin', '*');
    r.body = bytesToString(resp.body);
    return r;
  }

  /** /player：同源托管注入后的 player.html（对齐 Go /player 逻辑） */
  /** ★ 冷启动优化：优先返回部署时预注入的 player_boot.html（跳过运行时 WASM 注入） */
  private handlePlayer(): ProxyResponse {
    const r = new ProxyResponse();
    try {
      // ★ 优先读取预注入版本（RawfileDeploy.deploy 时已生成）
      const bootPath = this.resDir + '/web/player_boot.html';
      let html = readFileString(bootPath);
      if (html.length > 0) {
        r.code = 200;
        r.headers.set('Content-Type', 'text/html; charset=utf-8');
        r.headers.set('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0');
        r.body = html;
        return r;
      }
      // 回退：预注入版本不存在时，运行时注入（兼容旧版部署）
      const htmlPath = this.resDir + '/web/player.html';
      html = readFileString(htmlPath);
      const wasmB64 = bytesToBase64(readFileBytes(this.resDir + '/web/keygen_bg.wasm'));
      const ckeyB64 = bytesToBase64(readFileBytes(this.resDir + '/web/ts_module_body.js'));
      const yspB64 = bytesToBase64(readFileBytes(this.resDir + '/web/RJq7sO71JF.wasm'));
      html = html.replace('<!-- WASM_BASE64 -->',
        '<script>window.__wasmBase64="' + wasmB64 + '";</script>');
      html = html.replace('<!-- CKEY_CORE -->',
        '<script>window.__ckeyCoreB64="' + ckeyB64 + '";</script>');
      html = html.replace('<!-- YSPTICKET_WASM -->',
        '<script>window.__yspTicketWasmB64="' + yspB64 + '";</script>');
      html = html.split('127.0.0.1:18888').join('127.0.0.1:' + LISTEN_PORT);
      html = html.split('"/sapi/').join('"http://127.0.0.1:' + LISTEN_PORT + '/sapi/');
      html = html.split('ver=250813').join('ver=' + Date.now().toString());
      r.code = 200;
      r.headers.set('Content-Type', 'text/html; charset=utf-8');
      r.headers.set('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0');
      r.body = html;
    } catch (e) {
      r.code = 500;
      r.body = 'player.html error: ' + (e as Error).message;
    }
    return r;
  }

  /** /Library/CMGPlayer.json：返回解密算法开关配置（缺失会导致 wasm 解密不初始化 → 绿屏） */
  private handleCmgPlayerJson(): ProxyResponse {
    const r = new ProxyResponse();
    try {
      const data = readFileString(this.resDir + '/CMGPlayer.json');
      r.code = 200;
      r.headers.set('Content-Type', 'application/json; charset=utf-8');
      r.headers.set('Access-Control-Allow-Origin', '*');
      r.headers.set('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0');
      r.headers.set('Pragma', 'no-cache');
      r.body = data;
    } catch (e) {
      r.code = 404;
      r.body = 'CMGPlayer.json not found';
    }
    return r;
  }

  /** 写 HTTP 响应并关闭连接。body 为文本；binary 为二进制（优先于 body）。 */
  private sendResponse(conn: socket.TCPSocketConnection, code: number, headers: Map<string, string>, body: string, binary: Uint8Array): void {
    // 确定 payload 字节
    const payload = binary.byteLength > 0 ? binary : stringToBytes(body);
    let head = `HTTP/1.1 ${code} ${statusText(code)}\r\n`;
    head += `Content-Length: ${payload.length}\r\n`;
    let hasConn = false;
    headers.forEach((v: string, k: string) => {
      if (k.toLowerCase() === 'connection') {
        hasConn = true;
      }
      head += `${k}: ${v}\r\n`;
    });
    // ★ 响应后立即 close，必须显式声明 Connection: close。
    //   否则 HTTP/1.1 默认 keep-alive，客户端（尤其 Chromium 拉 TS/m3u8 的长连接）
    //   会复用已关闭的 socket，产生随机失败与重连开销。
    if (!hasConn) {
      head += 'Connection: close\r\n';
    }
    head += '\r\n';
    const headBuf = stringToBytes(head);
    const finalData = new Uint8Array(headBuf.length + payload.length);
    finalData.set(headBuf, 0);
    finalData.set(payload, headBuf.length);
    conn.send({ data: finalData.buffer as ArrayBuffer }).then(() => {
      conn.close();
    }).catch(() => {
      // ignore
    });
  }
}

/** sign 请求体 */
class SignReq {
  kind: string = '';
  fields: Record<string, string> = {};
}

function statusText(code: number): string {
  if (code === 200) {
    return 'OK';
  }
  if (code === 204) {
    return 'No Content';
  }
  if (code === 400) {
    return 'Bad Request';
  }
  if (code === 404) {
    return 'Not Found';
  }
  if (code === 502) {
    return 'Bad Gateway';
  }
  return 'OK';
}

/** 从响应/请求头中解析 Content-Length；缺失或非法返回 0 */
function parseContentLength(head: string): number {
  const m = /content-length\s*:\s*(\d+)/i.exec(head);
  if (m) {
    const n = parseInt(m[1], 10);
    return isNaN(n) ? 0 : n;
  }
  return 0;
}

/** 解析原始 HTTP 请求 */
function parseHttpRequest(raw: string): ParsedRequest {
  const req = new ParsedRequest();
  const idx = raw.indexOf('\r\n\r\n');
  const headPart = idx >= 0 ? raw.substring(0, idx) : raw;
  req.body = idx >= 0 ? raw.substring(idx + 4) : '';
  const lines = headPart.split('\r\n');
  if (lines.length === 0) {
    return req;
  }
  const reqLine = lines[0].split(' ');
  if (reqLine.length < 2) {
    return req;
  }
  req.method = reqLine[0];
  const fullPath = reqLine[1];
  const qIdx = fullPath.indexOf('?');
  req.path = qIdx >= 0 ? fullPath.substring(0, qIdx) : fullPath;
  req.query = qIdx >= 0 ? fullPath.substring(qIdx + 1) : '';
  for (let i = 1; i < lines.length; i++) {
    const ci = lines[i].indexOf(':');
    if (ci > 0) {
      const k = lines[i].substring(0, ci).toLowerCase();
      const v = lines[i].substring(ci + 1).trim();
      req.headers.set(k, v);
    }
  }
  return req;
}

/** GET 二进制响应 */
async function httpGetBinary(url: string, headers: Map<string, string>): Promise<BinaryResp> {
  const hc = http.createHttp();
  const resp = new BinaryResp();
  try {
    const headerObj: Record<string, string> = {};
    headers.forEach((v: string, k: string) => {
      headerObj[k] = v;
    });
    const httpResp = await hc.request(url, {
      method: http.RequestMethod.GET,
      header: headerObj,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 10000,
      readTimeout: 10000
    });
    resp.code = httpResp.responseCode as number;
    if (httpResp.result instanceof ArrayBuffer) {
      resp.body = new Uint8Array(httpResp.result);
    }
    const h = httpResp.header as Record<string, string>;
    resp.contentType = h['content-type'] ?? '';
  } catch (e) {
    resp.code = 502;
    resp.body = new Uint8Array(0);
  } finally {
    hc.destroy();
  }
  return resp;
}

/** POST 二进制响应 */
async function httpPost(url: string, body: string, headers: Map<string, string>): Promise<BinaryResp> {
  const hc = http.createHttp();
  const resp = new BinaryResp();
  try {
    const headerObj: Record<string, string> = {};
    headers.forEach((v: string, k: string) => {
      headerObj[k] = v;
    });
    const httpResp = await hc.request(url, {
      method: http.RequestMethod.POST,
      header: headerObj,
      extraData: body,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 10000,
      readTimeout: 10000
    });
    resp.code = httpResp.responseCode as number;
    if (httpResp.result instanceof ArrayBuffer) {
      resp.body = new Uint8Array(httpResp.result);
    }
    const h = httpResp.header as Record<string, string>;
    resp.contentType = h['content-type'] ?? '';
  } catch (e) {
    resp.code = 502;
    resp.body = new Uint8Array(0);
  } finally {
    hc.destroy();
  }
  return resp;
}

/** m3u8 相对 URI → 绝对 CDN URL；若提供 proxyPrefix 再把绝对 URL 包装成代理 URL */
function rewriteM3U8(body: string, m3u8URL: string, proxyPrefix?: string): string {
  let base = m3u8URL;
  const i = base.lastIndexOf('/');
  base = i >= 0 ? base.substring(0, i + 1) : '';

  const makeProxy = (url: string): string => {
    if (!proxyPrefix || url === '') {
      return url;
    }
    // 已经是代理地址/本地地址则不再套壳
    if (url.startsWith(proxyPrefix) || url.startsWith('/media/')) {
      return url;
    }
    if (url.startsWith('http://127.0.0.1') || url.startsWith('http://192.168.') || url.indexOf('localhost') >= 0) {
      return url;
    }
    return proxyPrefix + encodeURIComponent(url);
  };

  const resolve = (p: string): string => {
    if (p === '' || p.startsWith('data:')) {
      return p;
    }
    let abs = p;
    if (p.startsWith('http://') || p.startsWith('https://')) {
      abs = p;
    } else if (p.startsWith('/')) {
      const m = m3u8URL.match(/^(https?:\/\/[^/]+)/);
      abs = m ? m[1] + p : p;
    } else {
      abs = base + p;
    }
    return makeProxy(abs);
  };

  const lines = body.split('\n');
  for (let idx = 0; idx < lines.length; idx++) {
    const t = lines[idx].trim();
    if (t === '' || t.startsWith('#')) {
      continue;
    }
    lines[idx] = resolve(t);
  }
  let out = lines.join('\n');
  out = out.replace(/URI="([^"]*)"/g, (_m: string, p: string) => 'URI="' + resolve(p) + '"');
  return out;
}

// ==================== 工具：ArrayBuffer 与 string 互转 ====================

/** 字符串 → UTF-8 字节（正确处理中文等多字节字符） */
function stringToBytes(s: string): Uint8Array {
  const te = new util.TextEncoder();
  return new Uint8Array(te.encodeInto(s));
}

function stringToArrayBuffer(s: string): ArrayBuffer {
  return stringToBytes(s).buffer;
}

function arrayBufferToString(buf: ArrayBuffer): string {
  const u8 = new Uint8Array(buf);
  const td = new util.TextDecoder('utf-8');
  return td.decodeWithStream(u8, { stream: false });
}

function bytesToString(b: Uint8Array): string {
  const td = new util.TextDecoder('utf-8');
  return td.decodeWithStream(b, { stream: false });
}

/** 字节 → base64 字符串（无换行） */
function bytesToBase64(b: Uint8Array): string {
  const helper = new util.Base64Helper();
  return helper.encodeToStringSync(b);
}

/** 读沙箱文件为字符串 */
function readFileString(path: string): string {
  const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    const stat = fs.statSync(path);
    const buf = new ArrayBuffer(stat.size);
    const readLen = fs.readSync(file.fd, buf);
    return bytesToString(new Uint8Array(buf, 0, readLen));
  } finally {
    fs.closeSync(file);
  }
}

/** 读沙箱文件为字节 */
function readFileBytes(path: string): Uint8Array {
  const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    const stat = fs.statSync(path);
    const buf = new ArrayBuffer(stat.size);
    const readLen = fs.readSync(file.fd, buf);
    return new Uint8Array(buf, 0, readLen);
  } finally {
    fs.closeSync(file);
  }
}
