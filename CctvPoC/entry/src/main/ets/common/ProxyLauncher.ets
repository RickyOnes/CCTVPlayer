/**
 * ProxyLauncher - 代理的健康检查 / 拉起 / 守护
 *
 * 两种模式：
 * 1) External（联调）：代理跑在开发机（hmos_proxy.exe / hmos_proxy），壳只探测 /health。
 * 2) Arkts（真机正式）：代理由 ArktsProxy（本 App 内的本地 TCP HTTP 服务）实现，
 *    监听 127.0.0.1:18888，彻底摆脱开发机。
 *
 * 注：原 NATIVE 模式（Go c-shared .so 经 startNativeChildProcess 拉起）已废弃——
 *    手机形态不支持 native 子进程（返回 801 Capability not support），改用 ArkTS 本地服务。
 */
import { common } from '@kit.AbilityKit';
import { getText } from './CctvHttp';
import { ArktsProxy } from './ArktsProxy';
import { RawfileDeploy } from './RawfileDeploy';

export enum ProxyMode {
  EXTERNAL = 0,
  ARKTS = 1
}

export class ProxyLauncher {
  private base: string;
  private mode: ProxyMode;
  private onStatus: (ok: boolean, detail: string) => void;
  private ctx: common.UIAbilityContext | null = null;
  private arktsProxy: ArktsProxy | null = null;
  private timerId: number = -1;
  private watching: boolean = false;

  constructor(base: string, mode: ProxyMode, onStatus: (ok: boolean, detail: string) => void,
              ctx?: common.UIAbilityContext) {
    this.base = base;
    this.mode = mode;
    this.onStatus = onStatus;
    this.ctx = ctx ?? null;
  }

  /** 单次探测 /health */
  async check(): Promise<boolean> {
    try {
      const r = await getText(this.base, '/health', {}, 3000);
      return r.code === 0 && r.status === 200;
    } catch (e) {
      return false;
    }
  }

  /**
   * 确保代理就绪。
   * External：仅探测；Arkts：探测失败则启动 ArktsProxy 本地服务。
   */
  async ensure(): Promise<boolean> {
    if (await this.check()) {
      this.onStatus(true, '代理已就绪');
      return true;
    }
    if (this.mode === ProxyMode.ARKTS) {
      return await this.startArkts();
    }
    this.onStatus(false, '外部代理未就绪：请在开发机启动 hmos_proxy 并核对 IP');
    return false;
  }

  /** 启动 ArktsProxy 本地 HTTP 服务（先把 rawfile 资源部署到沙箱） */
  private async startArkts(): Promise<boolean> {
    const resDir = this.ctx ? this.ctx.filesDir + '/proxy' : '';
    if (this.ctx) {
      const deployed = await RawfileDeploy.deploy(this.ctx, resDir);
      if (!deployed) {
        this.onStatus(false, 'rawfile 部署失败');
        return false;
      }
    }
    this.arktsProxy = new ArktsProxy();
    let ok = false;
    let detail = '';
    await this.arktsProxy.start(resDir, (s: boolean, d: string) => {
      ok = s;
      detail = d;
    });
    if (ok) {
      if (await this.check()) {
        this.onStatus(true, '本机代理已启动');
        return true;
      }
    }
    this.onStatus(false, '本机代理启动失败: ' + detail);
    return false;
  }

  /** 守护：每 5s 探测，失联时提示 */
  startWatch(): void {
    if (this.watching) {
      return;
    }
    this.watching = true;
    this.timerId = setInterval(() => {
      this.check().then((ok: boolean) => {
        if (!ok && this.mode === ProxyMode.ARKTS) {
          this.onStatus(false, '本机代理失联');
        } else if (!ok) {
          this.onStatus(false, '代理失联');
        }
      });
    }, 5000);
  }

  stopWatch(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    this.watching = false;
  }
}
