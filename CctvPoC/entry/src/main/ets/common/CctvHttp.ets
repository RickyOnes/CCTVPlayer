/**
 * CctvHttp - 基于 @ohos.net.http 的轻量请求封装
 * 供 ProxyClient / ProxyLauncher / EPG 使用；全部请求指向 Go 代理 base。
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

export interface HttpResult {
  code: number;      // 0 = 成功
  status: number;    // HTTP 状态码
  body: string;      // 响应文本（UTF-8）
  msg: string;       // 错误信息
}

function build(): http.HttpRequest {
  return http.createHttp();
}

function parseBody(result: string | Object | ArrayBuffer | undefined): string {
  if (result === undefined || result === null) {
    return '';
  }
  if (typeof result === 'string') {
    return result;
  }
  if (result instanceof ArrayBuffer) {
    // ★ 修复：使用 TextDecoder 正确解码 UTF-8 多字节字符（中文等）
    try {
      const u8 = new Uint8Array(result as ArrayBuffer);
      const td = new util.TextDecoder('utf-8');
      return td.decodeWithStream(u8, { stream: false });
    } catch (e) {
      return '';
    }
  }
  return JSON.stringify(result);
}

function wrap(): HttpResult {
  return { code: 0, status: 0, body: '', msg: '' };
}

/**
 * 通用请求。url 为完整地址。
 */
export async function requestHttp(
  url: string,
  method: http.RequestMethod,
  headers: Record<string, string>,
  body: string,
  timeoutMs: number
): Promise<HttpResult> {
  const res = wrap();
  const client = build();
  try {
    const resp = await client.request(url, {
      method: method,
      header: headers,
      extraData: body,
      connectTimeout: timeoutMs,
      readTimeout: timeoutMs,
      expectDataType: http.HttpDataType.STRING,
    });
    res.status = resp.responseCode;
    res.body = parseBody(resp.result);
    if (resp.responseCode < 200 || resp.responseCode >= 300) {
      res.code = resp.responseCode;
      res.msg = 'HTTP ' + resp.responseCode;
    }
  } catch (e) {
    res.code = -1;
    res.msg = (e as Error).message;
  } finally {
    client.destroy();
  }
  return res;
}

export function buildUrl(host: string, port: number, path: string): string {
  return 'http://' + host + ':' + port + path;
}

export async function getText(
  base: string,
  path: string,
  headers: Record<string, string>,
  timeoutMs: number
): Promise<HttpResult> {
  return requestHttp(base + path, http.RequestMethod.GET, headers, '', timeoutMs);
}

export async function postForm(
  base: string,
  path: string,
  fields: Record<string, string>,
  headers: Record<string, string>,
  timeoutMs: number
): Promise<HttpResult> {
  const parts: string[] = [];
  const keys = Object.keys(fields);
  for (const k of keys) {
    parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(fields[k]));
  }
  const body = parts.join('&');
  // ★ form body 必须标 x-www-form-urlencoded（对齐桌面版 auth）。
  //   之前没设 Content-Type → 默认 application/json → 源站按 JSON 解析 form → 10014 RandStr有误
  const h: Record<string, string> = { 'Content-Type': 'application/x-www-form-urlencoded' };
  const hkeys = Object.keys(headers);
  for (const k of hkeys) {
    h[k] = headers[k];
  }
  return requestHttp(base + path, http.RequestMethod.POST, h, body, timeoutMs);
}

export async function postJson(
  base: string,
  path: string,
  json: string,
  headers: Record<string, string>,
  timeoutMs: number
): Promise<HttpResult> {
  const h: Record<string, string> = { 'Content-Type': 'application/json' };
  const hkeys = Object.keys(headers);
  for (const k of hkeys) {
    h[k] = headers[k];
  }
  return requestHttp(base + path, http.RequestMethod.POST, h, json, timeoutMs);
}
