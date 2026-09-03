/**
 * ProxySigner - 央视频 4 类 MD5 签名算法（ArkTS 重写版）。
 *
 * 与 hmos/proxy/sign.go 完全对齐，盐值来自桌面版 CCTVPlayer/PlayerService.cs。
 * MD5 采用纯 TS 实现（不依赖系统 crypto 策略，避免 MD5 被禁用）。
 */

const AUTH_SALT = 'n@7QKk%YeSjfw%22';
const LIVE_SALT_TC = '0f$IVHi9Qno?G';

/** 签名种类 */
export type SignKind = 'auth' | 'sdkInput' | 'bodySig' | 'kv';

/** 计算指定种类的签名。fields 为参与签名的字段字典。 */
export function computeSign(kind: SignKind, fields: Record<string, string>): string {
  switch (kind) {
    case 'auth':
      return computeAuthSignature(fields);
    case 'sdkInput':
      return computeLiveSdkInput(fields);
    case 'bodySig':
      return computeLiveBodySignature(fields);
    case 'kv':
      return computeKvCollectSignature(fields);
    default:
      return '';
  }
}

/** auth：字段按 key 字母序（Ordinal/ASCII）拼接 k=v 用 & 连接，末尾加 authSalt。 */
function computeAuthSignature(fields: Record<string, string>): string {
  const keys = Object.keys(fields).sort();
  const sb: string[] = [];
  keys.forEach((k, i) => {
    if (i > 0) {
      sb.push('&');
    }
    sb.push(k + '=' + fields[k]);
  });
  sb.push(AUTH_SALT);
  return md5Hex(sb.join(''));
}

/** bodySig：Ordinal 排序，排除 signature，末尾加 liveSaltTc。 */
function computeLiveBodySignature(fields: Record<string, string>): string {
  const keys = Object.keys(fields).sort();
  const sb: string[] = [];
  let first = true;
  for (const k of keys) {
    if (k === 'signature') {
      continue;
    }
    if (!first) {
      sb.push('&');
    }
    first = false;
    sb.push(k + '=' + fields[k]);
  }
  sb.push(LIVE_SALT_TC);
  return md5Hex(sb.join(''));
}

/**
 * sdkInput：对应 C# ComputeLiveSdkInput，用 en-US 文化的 localeCompare 排序，
 * 导致 app_version 排在 appVer 之前（与 Ordinal 不同）。排除 rand_str 和 signature。
 * 出错表现：服务器返回 401。
 */
function computeLiveSdkInput(fields: Record<string, string>): string {
  const keys = Object.keys(fields);
  // en-US localeCompare 对齐 C# CompareOptions.None（区分大小写、按码位）
  keys.sort((a, b) => a.localeCompare(b, 'en-US'));
  const sb: string[] = [];
  let first = true;
  for (const k of keys) {
    if (k === 'rand_str' || k === 'signature') {
      continue;
    }
    if (!first) {
      sb.push('&');
    }
    first = false;
    sb.push(k + '=' + fields[k]);
  }
  return md5Hex(sb.join(''));
}

/** kv：Ordinal 排序，排除 signature，末尾加 authSalt。 */
function computeKvCollectSignature(fields: Record<string, string>): string {
  const keys = Object.keys(fields).sort();
  const sb: string[] = [];
  let first = true;
  for (const k of keys) {
    if (k === 'signature') {
      continue;
    }
    if (!first) {
      sb.push('&');
    }
    first = false;
    sb.push(k + '=' + fields[k]);
  }
  sb.push(AUTH_SALT);
  return md5Hex(sb.join(''));
}

// ==================== 纯 TS MD5 实现 ====================

function md5Hex(s: string): string {
  const bytes = utf8Bytes(s);
  const digest = md5(bytes);
  return bytesToHex(digest);
}

function utf8Bytes(s: string): number[] {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    let c = s.charCodeAt(i);
    if (c < 0x80) {
      out.push(c);
    } else if (c < 0x800) {
      out.push(0xC0 | (c >> 6), 0x80 | (c & 0x3F));
    } else if (c < 0xD800 || c >= 0xE000) {
      out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
    } else {
      // surrogate pair
      i++;
      const c2 = 0x10000 + (((c & 0x3FF) << 10) | (s.charCodeAt(i) & 0x3FF));
      out.push(0xF0 | (c2 >> 18), 0x80 | ((c2 >> 12) & 0x3F), 0x80 | ((c2 >> 6) & 0x3F), 0x80 | (c2 & 0x3F));
    }
  }
  return out;
}

function md5(input: number[]): number[] {
  const msg = input.slice();
  const origLenBits = msg.length * 8;
  msg.push(0x80);
  while (msg.length % 64 !== 56) {
    msg.push(0);
  }
  // 长度按小端 64bit 追加（低位在前）
  const low = origLenBits & 0xFFFFFFFF;
  const high = Math.floor(origLenBits / 0x100000000);
  msg.push(low & 0xFF, (low >>> 8) & 0xFF, (low >>> 16) & 0xFF, (low >>> 24) & 0xFF);
  msg.push(high & 0xFF, (high >>> 8) & 0xFF, (high >>> 16) & 0xFF, (high >>> 24) & 0xFF);

  let a0 = 0x67452301;
  let b0 = 0xEFCDAB89;
  let c0 = 0x98BADCFE;
  let d0 = 0x10325476;

  const S = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];

  const K: number[] = [];
  for (let i = 0; i < 64; i++) {
    K.push(Math.floor(Math.abs(Math.sin(i + 1)) * 0x100000000) >>> 0);
  }

  for (let off = 0; off < msg.length; off += 64) {
    const M: number[] = [];
    for (let i = 0; i < 16; i++) {
      M.push(msg[off + i * 4] | (msg[off + i * 4 + 1] << 8) | (msg[off + i * 4 + 2] << 16) | (msg[off + i * 4 + 3] << 24));
    }
    let A = a0;
    let B = b0;
    let C = c0;
    let D = d0;
    for (let i = 0; i < 64; i++) {
      let F: number;
      let g: number;
      if (i < 16) {
        F = (B & C) | (~B & D);
        g = i;
      } else if (i < 32) {
        F = (D & B) | (~D & C);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        F = B ^ C ^ D;
        g = (3 * i + 5) % 16;
      } else {
        F = C ^ (B | ~D);
        g = (7 * i) % 16;
      }
      const tmp = D;
      D = C;
      C = B;
      const sum = (A + F + K[i] + M[g]) >>> 0;
      const rot = S[i];
      const rotated = ((sum << rot) | (sum >>> (32 - rot))) >>> 0;
      B = (B + rotated) >>> 0;
      A = tmp;
    }
    a0 = (a0 + A) >>> 0;
    b0 = (b0 + B) >>> 0;
    c0 = (c0 + C) >>> 0;
    d0 = (d0 + D) >>> 0;
  }

  const out: number[] = [];
  [a0, b0, c0, d0].forEach((v) => {
    out.push(v & 0xFF, (v >>> 8) & 0xFF, (v >>> 16) & 0xFF, (v >>> 24) & 0xFF);
  });
  return out;
}

function bytesToHex(b: number[]): string {
  let s = '';
  for (const x of b) {
    s += (x < 16 ? '0' : '') + x.toString(16);
  }
  return s;
}
