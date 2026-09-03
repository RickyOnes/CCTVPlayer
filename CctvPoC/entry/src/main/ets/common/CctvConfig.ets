/**
 * CctvConfig - 央视频播放器常量配置（与桌面版 PlayerService.cs 对齐）
 * 鸿蒙版专用，所有业务请求经 Go 代理 (hmos_proxy) 转发，本文件只存静态常量。
 */

// ===== 应用与设备标识 =====
export const YspAppId: string = '519748109';
export const Guid: string = 'mra3u75l_jdrj8csvhkk';
export const VappId: string = '59306155';
export const Vsecret: string = 'b42702bf7309a179d102f3d51b1add2fda0bc7ada64cb801';
export const AppVer: string = 'V1.0.0';

// ===== 请求头 =====
export const Ua: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36';
export const Cookie: string =
  'guid=mra3u75l_jdrj8csvhkk; versionName=99.99.99; versionCode=999999; vplatform=109; platformVersion=Chrome; deviceModel=150; newLogin=1; pc_version=1.1.16; ysp_uinfo_pc=';

// ===== 签名盐（与桌面版一致，Go /sign 也用此值）=====
export const AuthSalt: string = 'n@7QKk%YeSjfw%22';
export const LiveSaltTc: string = '0f$IVHi9Qno?G';

// ===== kvcollect 心跳 =====
export const KvBossId: string = '99150';
export const KvPwd: string = '1999332929';
export const KvUrl: string = 'https://aatc-api.yangshipin.cn/kvcollect';
export const KvIntervalMs: number = 60 * 1000;

// ===== 代理配置 =====
// ★ Native 模式：代理（libhmos_proxy.so）运行在手机沙箱内，壳经本机回环 127.0.0.1 访问。
//   如需切回「开发机联调」（External），再改回开发机局域网 IP 即可。
export const ProxyDefaultHost: string = '127.0.0.1';
export const ProxyPort: number = 18888;
export const ProxyTimeoutMs: number = 12000;

// ===== 导航目标（域名锁 / wasm 密钥种子依赖，禁止改为 127.0.0.1）=====
// 与桌面版一致：https://yangshipin.cn/tv/home?pid={Pid}（cKey 的 documentURL 也用它）
export const NavUrl: string = 'https://yangshipin.cn/tv/home?pid=600001859';
