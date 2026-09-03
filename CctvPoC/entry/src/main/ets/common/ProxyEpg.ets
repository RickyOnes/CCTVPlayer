/**
 * ProxyEpg - EPG 节目单 protobuf → JSON 解码（ArkTS 重写版）。
 * 与 hmos/proxy/main.go 的 readVarint/parseEpgProgram/capi 解码完全对齐。
 */

class VarintResult {
  value: number = 0;
  n: number = 0;

  constructor(value: number, n: number) {
    this.value = value;
    this.n = n;
  }
}

/** 读取 protobuf varint，返回 [值, 消耗字节数] */
function readVarint(b: Uint8Array, start: number): VarintResult {
  let v = 0;
  let s = 0;
  for (let i = start; i < b.length; i++) {
    v |= (b[i] & 0x7F) << s;
    if (b[i] < 0x80) {
      return new VarintResult(v, i - start + 1);
    }
    s += 7;
  }
  return new VarintResult(0, 0);
}

/** 解析单个节目 protobuf 消息 → JSON 字符串。字段：[1]id [2]title [5]start [6]end [7]duration */
function parseEpgProgram(b: Uint8Array): string {
  let id = '';
  let title = '';
  let start = '';
  let end = '';
  let dur = 0;
  let off = 0;
  while (off < b.length) {
    const tagRes = readVarint(b, off);
    const tag = tagRes.value;
    if (tagRes.n === 0) {
      break;
    }
    off += tagRes.n;
    const fnum = tag >> 3;
    const wtype = tag & 0x7;
    if (wtype === 0) { // varint
      const vRes = readVarint(b, off);
      off += vRes.n;
      if (fnum === 7) {
        dur = vRes.value;
      }
    } else if (wtype === 2) { // length-delimited
      const lenRes = readVarint(b, off);
      off += lenRes.n;
      const length = lenRes.value;
      const s = bytesToString(b.subarray(off, off + length));
      off += length;
      if (fnum === 1) {
        id = s;
      } else if (fnum === 2) {
        title = s;
      } else if (fnum === 5) {
        start = s;
      } else if (fnum === 6) {
        end = s;
      }
    } else {
      return ''; // unknown wire type
    }
  }
  if (title === '') {
    return '';
  }
  let st = start;
  let et = end;
  if (dur > 0 && st === '' && et === '') {
    const hh = Math.floor(dur / 3600);
    const mm = Math.floor((dur % 3600) / 60);
    st = pad2(hh) + ':' + pad2(mm);
  }
  const titleEsc = title.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  return `{"id":"${id}","title":"${titleEsc}","start":"${st}","end":"${et}"}`;
}

function pad2(n: number): string {
  return n < 10 ? '0' + String(n) : String(n);
}

/** 将整个 capi protobuf 响应解码为 JSON 数组字符串。 */
export function decodeEpgProtobuf(data: Uint8Array): string {
  const jsonParts: string[] = [];
  let off = 0;
  while (off < data.length) {
    const tagRes = readVarint(data, off);
    if (tagRes.n === 0) {
      break;
    }
    off += tagRes.n;
    const fnum = tagRes.value >> 3;
    const wtype = tagRes.value & 0x7;
    if (wtype === 0) { // varint
      const vRes = readVarint(data, off);
      off += vRes.n;
      // fnum==1 为 total，跳过
    } else if (wtype === 2) { // length-delimited
      const lenRes = readVarint(data, off);
      off += lenRes.n;
      const length = lenRes.value;
      const sub = data.subarray(off, off + length);
      off += length;
      if (fnum === 2) { // program message
        const prog = parseEpgProgram(sub);
        if (prog !== '') {
          jsonParts.push(prog);
        }
      }
    } else {
      break;
    }
  }
  return '[' + jsonParts.join(',') + ']';
}

/** UTF-8 字节转字符串（用于 protobuf 字段） */
function bytesToString(b: Uint8Array): string {
  let s = '';
  let i = 0;
  while (i < b.length) {
    const c = b[i];
    if (c < 0x80) {
      s += String.fromCharCode(c);
      i += 1;
    } else if (c < 0xE0) {
      s += String.fromCharCode(((c & 0x1F) << 6) | (b[i + 1] & 0x3F));
      i += 2;
    } else if (c < 0xF0) {
      s += String.fromCharCode(((c & 0x0F) << 12) | ((b[i + 1] & 0x3F) << 6) | (b[i + 2] & 0x3F));
      i += 3;
    } else {
      s += String.fromCharCode(((c & 0x07) << 18) | ((b[i + 1] & 0x3F) << 12) | ((b[i + 2] & 0x3F) << 6) | (b[i + 3] & 0x3F));
      i += 4;
    }
  }
  return s;
}
