// gen_yspticket.cjs
// 动态生成央视频 yspticket (复刻官方 _c + RJq7sO71JF.wasm 的 AES-CTR + PCG 尾缀)
// 用法: node gen_yspticket.cjs <livepid> <ts> <cnlid> <guid> <yspappid> <appVer> <seed> <wasmPath>
//   - ts      : 认证响应里的 ts (秒, 字符串), 同时作为 _c 第2参数
//   - seed    : 喂给 wasm 的 _time import (PCG 尾缀种子), 应与 ts 相同
//   - wasmPath: RJq7sO71JF.wasm 的绝对/相对路径
// 成功: 仅把 62 字节 hex 打到 stdout; 失败: 把错误打到 stderr 并以非零退出码结束。

const fs = require('fs');

function fail(msg) { process.stderr.write('GEN_YSPTICKET_ERROR: ' + msg + '\n'); process.exit(2); }

try {
  const [, , livepid, ts, cnlid, guid, yspappid, appVer, seedStr, wasmPath] = process.argv;
  if (!livepid || !ts || !guid || !yspappid || !wasmPath) {
    fail('参数不足: 需要 livepid ts cnlid guid yspappid appVer seed wasmPath');
  }
  const seed = parseInt(seedStr && seedStr.length ? seedStr : ts, 10);
  if (!Number.isFinite(seed)) fail('seed/ts 不是合法整数: ' + seedStr);

  if (!fs.existsSync(wasmPath)) fail('找不到 wasm: ' + wasmPath);

  const buf = fs.readFileSync(wasmPath);
  const mem = new WebAssembly.Memory({ initial: 256, maximum: 256 });
  const tbl = new WebAssembly.Table({ initial: 1024, maximum: 4096, element: 'anyfunc' });

  // Emscripten 风格 import: module "a"
  //   "a" -> memory, "b" -> table
  //   "O" -> is_browser_environment (必须返回 1, 否则 _aes_encrypt_ctr 走非浏览器分支)
  //   "d" -> _time(ptr): 写入 seed 到 ptr 并返回 seed (PCG 尾缀种子)
  //   其余 import 一律返回 0 (yspticket 路径不会真正用到)
  function fnImport(name) {
    return function (...args) {
      if (name === 'O' || name.includes('browser')) return 1;
      if (name === 'd') {
        if (args[0]) new Int32Array(mem.buffer)[args[0] >> 2] = seed;
        return seed;
      }
      return 0;
    };
  }
  // moduleProxy: a.a->memory, a.b->table, 其余函数 import->fnImport 兜底
  const moduleProxy = new Proxy({}, {
    get(t, modname) {
      return new Proxy({ a: mem, b: tbl }, {
        get(t2, fname) {
          if (fname === 'a') return mem;
          if (fname === 'b') return tbl;
          return fnImport(fname);
        },
      });
    },
  });

  (async () => {
    let ex;
    try {
      const mod = await WebAssembly.instantiate(buf, moduleProxy);
      ex = mod.instance.exports;
    } catch (e) { fail('wasm 实例化失败: ' + e.message); }

    const T = ex.T, R = ex.R, S = ex.S;
    if (typeof T !== 'function' || typeof R !== 'function' || typeof S !== 'function') {
      fail('wasm 缺少导出 T/R/S (aes_encrypt_ctr/malloc/get_encrypt_str_len)');
    }

    const enc = new TextEncoder();
    function sp(s) { const e = enc.encode(s); const p = R(e.length + 1); new Uint8Array(mem.buffer, p, e.length + 1).set(e); return p; }

    const a = sp(livepid), s = sp(ts), c = sp(cnlid), u = sp(guid), l = sp(yspappid), f = sp(appVer);
    let d;
    try { d = S(a, s, c, u, l, f); } catch (e) { fail('get_encrypt_str_len 失败: ' + e.message); }
    if (!d || d <= 0) fail('get_encrypt_str_len 返回非法长度: ' + d);

    const w = R(d);
    T(a, s, c, u, l, f, w);
    const out = new Uint8Array(mem.buffer, w, d);
    let hex = '';
    for (let i = 0; i < d; i++) hex += ('0' + out[i].toString(16)).slice(-2);
    process.stdout.write(hex);
  })();
} catch (e) {
  fail(e && e.message ? e.message : String(e));
}
