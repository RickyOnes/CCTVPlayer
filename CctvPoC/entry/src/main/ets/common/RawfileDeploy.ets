/**
 * RawfileDeploy - 首启把 HAP rawfile 内嵌的代理运行资源复制到沙箱 files/ 目录。
 *
 * 背景：HAP 内 rawfile 只读，Go 代理（libhmos_proxy.so 原生模式）运行时需要读写
 * cacert.pem / sapi_cache / web/ 等资源，且路径必须是可写的沙箱路径。
 * 本模块在 Native 模式首次启动前调用，把资源平铺复制到 destDir（建议 filesDir/proxy/），
 * 之后通过 HMOS_PROXY_BASE / HMOS_WEB_DIR 环境语义（.so 内固定默认路径）访问。
 *
 * ★ 冷启动优化：部署时预注入 WASM 数据到 player.html，生成 player_boot.html。
 *   WebView 直接 file:// 加载 player_boot.html，跳过代理启动+HTTP 请求。
 *
 * 清单与 hmos/proxy/pack-hap-assets.ps1 打包内容一一对应，增删资源需同步两处。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { injectSapiAsset, SapiInjectResult, SAPI_INJECT_VER } from './CmgInject';

const TAG = 'CctvDeploy';
const DOMAIN = 0x8888;

export class RawfileDeploy {
  /** 需从 rawfile 复制到 destDir 的清单（相对路径）。
   *  ★ 注意：代理本体 libhmos_proxy.so 走 HAP 的 libs/arm64-v8a/（系统自动加载），
   *    不在 rawfile 内；此处只部署 .so 运行时需要的静态资源（cacert/web/sapi_cache）。 */
  static readonly FILES: string[] = [
    'cacert.pem',
    'CMGPlayer.json',
    'web/player.html',
    'web/keygen_bg.wasm',
    'web/RJq7sO71JF.wasm',
    'web/ts_module_body.js',
    'sapi_cache/assets_2025_wasm_cmg.worker.js',
    'sapi_cache/assets_2025_wasm_hls.cmg.js'
  ];

  /** 需在部署期预注入的 sapi 脚本名（对应上面两个 rawfile 的文件名部分） */
  private static readonly SAPI_ASSETS: string[] = ['cmg.worker.js', 'hls.cmg.js'];

  private static log(msg: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', msg);
  }

  private static err(msg: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', msg);
  }

  /** 递归确保父目录存在（已存在时吞掉报错） */
  private static ensureDir(dir: string): void {
    try {
      fs.mkdirSync(dir, true);
    } catch (e) {
      // 目录已存在等场景忽略
    }
  }

  /** 单文件复制：rawfile -> destPath */
  private static async copyOne(ctx: common.UIAbilityContext, relPath: string, destPath: string): Promise<void> {
    try {
      const u8: Uint8Array = await ctx.resourceManager.getRawFileContent(relPath);
      const file = fs.openSync(destPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, u8.buffer as ArrayBuffer);
      } finally {
        fs.closeSync(file);
      }
      RawfileDeploy.log(`deploy OK: ${relPath} (${u8.length} bytes)`);
    } catch (e) {
      const be = e as BusinessError;
      RawfileDeploy.err(`deploy FAIL: ${relPath} err=${be?.code} ${be?.message}`);
      throw new Error(`deploy FAIL: ${relPath} err=${be?.code} ${be?.message}`);
    }
  }

  /**
   * ★ 冷启动优化：读取已部署的 player.html + WASM 文件，注入 base64 数据，
   *   生成预渲染的 player_boot.html，供 WebView file:// 直接加载。
   *   跳过代理启动 + HTTP 请求，节省 ~500-1000ms。
   */
  static injectPlayerHtml(destDir: string): boolean {
    try {
      const htmlPath = destDir + '/web/player.html';
      const wasmPath = destDir + '/web/keygen_bg.wasm';
      const ckeyPath = destDir + '/web/ts_module_body.js';
      const yspPath = destDir + '/web/RJq7sO71JF.wasm';
      const outPath = destDir + '/web/player_boot.html';

      // 读取 HTML 和 WASM/JS 资源
      const html = RawfileDeploy.readTextFile(htmlPath);
      if (!html) {
        RawfileDeploy.err('injectPlayerHtml: 读取 player.html 失败');
        return false;
      }
      const wasmB64 = RawfileDeploy.readAndBase64(wasmPath);
      const ckeyB64 = RawfileDeploy.readAndBase64(ckeyPath);
      const yspB64 = RawfileDeploy.readAndBase64(yspPath);
      if (!wasmB64 || !ckeyB64 || !yspB64) {
        RawfileDeploy.err('injectPlayerHtml: 读取 WASM/JS 资源失败');
        return false;
      }

      // 注入 3 个 base64 资源（与 ArktsProxy.handlePlayer 逻辑一致）
      let result = html;
      result = result.replace('<!-- WASM_BASE64 -->',
        '<script>window.__wasmBase64="' + wasmB64 + '";</script>');
      result = result.replace('<!-- CKEY_CORE -->',
        '<script>window.__ckeyCoreB64="' + ckeyB64 + '";</script>');
      result = result.replace('<!-- YSPTICKET_WASM -->',
        '<script>window.__yspTicketWasmB64="' + yspB64 + '";</script>');
      // URL 改写：127.0.0.1:18888 → 本机；/sapi/ 相对 → 绝对
      result = result.split('127.0.0.1:18888').join('127.0.0.1:18888');
      result = result.split('"/sapi/').join('"http://127.0.0.1:18888/sapi/');
      // 缓存破坏
      result = result.split('ver=250813').join('ver=' + Date.now().toString());

      // 写入 player_boot.html
      const encoder = new util.TextEncoder();
      const bytes = encoder.encodeInto(result);
      const file = fs.openSync(outPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, bytes.buffer as ArrayBuffer);
      } finally {
        fs.closeSync(file);
      }
      RawfileDeploy.log(`injectPlayerHtml OK -> ${outPath} (${bytes.length} bytes)`);
      return true;
    } catch (e) {
      RawfileDeploy.err('injectPlayerHtml FAIL: ' + (e as Error).message);
      return false;
    }
  }

  /**
   * ★ 冷启动优化（2026-08-30）：预先把注入后的 CMG 脚本落到沙箱，
   *   让 /sapi 在首播关键路径上直接读盘（~10ms），省掉 2.44s 的网络拉取 + 注入。
   *
   * ★★ 安全前提：注入必须**锚点全部命中**才写盘。随包 rawfile 是 2025-08-13 的
   *   快照（CMG_BTime=Aug 13 2025），若上游改了算法导致锚点失配，
   *   这里会跳过写盘 → ArktsProxy 自动回退到网络路径 → 行为与优化前完全一致。
   *   宁可慢，不可静默坏帧。
   *
   * 幂等：目标文件已存在则直接返回。
   */
  static async buildSapiCache(destDir: string): Promise<void> {
    for (const name of RawfileDeploy.SAPI_ASSETS) {
      const outPath: string = destDir + '/sapi_cache/inj_' + SAPI_INJECT_VER + '_' + name;
      try {
        if (fs.statSync(outPath).size > 0) {
          RawfileDeploy.log(`sapiCache 已存在，跳过: ${name}`);
          continue;
        }
      } catch (e) {
        // 不存在 → 需要构建
      }
      const srcPath: string = destDir + '/sapi_cache/assets_2025_wasm_' + name;
      const raw: string = RawfileDeploy.readTextFile(srcPath);
      if (!raw) {
        RawfileDeploy.err(`sapiCache 源缺失: ${srcPath}`);
        continue;
      }
      const res: SapiInjectResult = injectSapiAsset(name, raw, 18888);
      if (!res.ok) {
        // ★ 锚点失配：绝不写盘，让运行期走网络
        RawfileDeploy.err(`sapiCache 锚点失配，放弃预注入(将回退网络): ${name} ${res.detail}`);
        continue;
      }
      try {
        const encoder = new util.TextEncoder();
        const bytes = encoder.encodeInto(res.text);
        const file = fs.openSync(outPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(file.fd, bytes.buffer as ArrayBuffer);
        } finally {
          fs.closeSync(file);
        }
        RawfileDeploy.log(`sapiCache OK: ${name} (${bytes.length} bytes) ${res.detail}`);
      } catch (e) {
        RawfileDeploy.err(`sapiCache 写入失败: ${name} ${(e as Error).message}`);
      }
    }
  }

  /** 读取文本文件 */
  private static readTextFile(path: string): string {
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const stat = fs.statSync(path);
        const buf = new ArrayBuffer(stat.size);
        const readLen = fs.readSync(file.fd, buf);
        const td = new util.TextDecoder('utf-8');
        return td.decodeWithStream(new Uint8Array(buf, 0, readLen), { stream: false });
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      return '';
    }
  }

  /** 读取文件并转为 base64 */
  private static readAndBase64(path: string): string {
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const stat = fs.statSync(path);
        const buf = new ArrayBuffer(stat.size);
        const readLen = fs.readSync(file.fd, buf);
        const u8 = new Uint8Array(buf, 0, readLen);
        const helper = new util.Base64Helper();
        return helper.encodeToStringSync(u8);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      return '';
    }
  }

  /**
   * 执行全量部署。destDir 建议 context.filesDir + '/proxy'。
   * 重复调用幂等（覆盖写）。
   */
  static async deploy(ctx: common.UIAbilityContext, destDir: string): Promise<boolean> {
    try {
      RawfileDeploy.ensureDir(destDir);
      for (const rel of RawfileDeploy.FILES) {
        const parts = rel.split('/');
        if (parts.length > 1) {
          // 确保子目录（web / sapi_cache）存在
          RawfileDeploy.ensureDir(destDir + '/' + parts[0]);
        }
        const destPath = destDir + '/' + rel;
        await RawfileDeploy.copyOne(ctx, rel, destPath);
      }
      // ★ 冷启动优化：部署完成后立即预注入 WASM，生成 player_boot.html
      RawfileDeploy.injectPlayerHtml(destDir);
      // ★ 冷启动优化：预注入 CMG 脚本，生成 /sapi 本地缓存（省首播 2.44s）
      await RawfileDeploy.buildSapiCache(destDir);
      RawfileDeploy.log(`deploy complete -> ${destDir}`);
      return true;
    } catch (e) {
      RawfileDeploy.err('deploy aborted: ' + (e as BusinessError)?.message);
      return false;
    }
  }
}
