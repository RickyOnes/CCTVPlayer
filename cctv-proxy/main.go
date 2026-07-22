package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	utls "github.com/refraction-networking/utls"
	"golang.org/x/net/http2"
)

var targetHost = "player-api.yangshipin.cn"

var pathMap = map[string]string{
	"/auth":          "/v1/player/auth",
	"/get-live-info": "/v1/player/get_live_info",
	"/health":        "",
}

// open-token 转发到 h5access (不同于 player-api)
var openTokenHost = "h5access.yangshipin.cn"

const chromeUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

func addCors(w http.ResponseWriter) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "*")
}

// findCMGPlayerJSON 从 exe 所在目录向上遍历，定位 workspace 下的 央视频官方源文件/CMGPlayer.json。
// 兼容开发调试（exe 在 cctv-proxy/）和生产运行（exe 在 CCTVPlayer/bin/.../win-x64/）。
func findCMGPlayerJSON() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	dir := filepath.Dir(exe)
	for i := 0; i < 12; i++ {
		p := filepath.Join(dir, "央视频官方源文件", "CMGPlayer.json")
		if _, err := os.Stat(p); err == nil {
			return p
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return ""
}

func setReqHeaders(req *http.Request, extra http.Header) {
	req.Header.Set("User-Agent", chromeUA)
	req.Header.Set("Referer", "https://yangshipin.cn/")
	req.Header.Set("Origin", "https://yangshipin.cn")
	for k, vs := range extra {
		for _, v := range vs {
			req.Header.Set(k, v)
		}
	}
}

// readVarint 从字节切片读取一个 protobuf varint, 返回 (值, 消耗字节数)
func readVarint(b []byte) (uint64, int) {
	var v uint64
	var s uint
	for i, c := range b {
		v |= uint64(c&0x7F) << s
		if c < 0x80 {
			return v, i + 1
		}
		s += 7
	}
	return 0, 0
}

// parseEpgProgram 解析单个节目 protobuf 消息 → JSON 行
// 字段: [1]id(string) [2]title(string) [5]start_time(string) [6]end_time(string) [7]duration(varint)
func parseEpgProgram(b []byte) string {
	var id, title, start, end string
	var dur int64
	off := 0
	for off < len(b) {
		tag, n := readVarint(b[off:])
		if n == 0 {
			break
		}
		off += n
		fnum, wtype := int(tag>>3), int(tag&0x7)
		switch {
		case wtype == 0: // varint
			v, n := readVarint(b[off:])
			off += n
			if fnum == 7 {
				dur = int64(v)
			}
		case wtype == 2: // length-delimited (string/bytes)
			length, ln := readVarint(b[off:])
			off += ln
			s := string(b[off : off+int(length)])
			off += int(length)
			switch fnum {
			case 1:
				id = s
			case 2:
				title = s
			case 5:
				start = s
			case 6:
				end = s
			}
		default:
			return "" // unknown wire type, abort
		}
	}
	if title == "" {
		return ""
	}
	// 计算显示用的时间格式化 (HH:MM-HH:MM 或直接用原始字符串)
	st, et := start, end
	if dur > 0 && st == "" && et == "" {
		// 无 start/end 字符串时用 duration 构造
		st = fmt.Sprintf("%02d:%02d", dur/3600, (dur%3600)/60)
	}
	titleEsc := strings.ReplaceAll(strings.ReplaceAll(title, "\\", "\\\\"), "\"", "\\\"")
	return fmt.Sprintf(`{"id":"%s","title":"%s","start":"%s","end":"%s"}`,
		id, titleEsc, st, et)
}

func main() {
	port := "18888"
	if p := os.Getenv("PROXY_PORT"); p != "" {
		port = p
	}

	// 强制直连, 禁用系统代理
	os.Setenv("HTTP_PROXY", "")
	os.Setenv("HTTPS_PROXY", "")

	// 自定义 DNS (系统 DNS 走代理不通, 用公共 DNS)
	resolver := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			d := &net.Dialer{Timeout: 5 * time.Second}
			return d.DialContext(ctx, "udp", "114.114.114.114:53")
		},
	}

	// ★ 试多个 Chrome 指纹，优先使用与 UA 匹配的 Chrome 150
	chromeIDs := []utls.ClientHelloID{
		utls.HelloChrome_Auto,
		utls.HelloChrome_133,
		utls.HelloChrome_131,
		utls.HelloChrome_120,
		utls.HelloChrome_100,
		utls.HelloChrome_96,
	}
	chromeIdx := 0

	tryDial := func(ctx context.Context, network, addr string) (net.Conn, error) {
		host, port, _ := net.SplitHostPort(addr)
		ips, err := resolver.LookupHost(ctx, host)
		if err != nil {
			return nil, fmt.Errorf("dns: %w", err)
		}
		if len(ips) == 0 {
			return nil, fmt.Errorf("dns: no IP for %s", host)
		}
		target := net.JoinHostPort(ips[0], port)

		d := &net.Dialer{Timeout: 10 * time.Second}
		tcpConn, err := d.DialContext(ctx, network, target)
		if err != nil {
			return nil, err
		}

		helloID := chromeIDs[chromeIdx%len(chromeIDs)]
		chromeIdx++
		uconn := utls.UClient(tcpConn, &utls.Config{
			ServerName: host,
		}, helloID)
		if err := uconn.HandshakeContext(ctx); err != nil {
			tcpConn.Close()
			return nil, fmt.Errorf("utls: %w", err)
		}
		return uconn, nil
	}

	// 先用 http2.Transport (HTTP/2)
	clientH2 := &http.Client{
		Transport: &http2.Transport{
			DialTLSContext: func(ctx context.Context, network, addr string, _ *tls.Config) (net.Conn, error) {
				return tryDial(ctx, network, addr)
			},
		},
	}
	// h1 回退
	clientH1 := &http.Client{
		Transport: &http.Transport{
			DialTLSContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return tryDial(ctx, network, addr)
			},
		},
	}
	// ★ h1 直连 (CDN 实测不支持 h2, 用 h1 避免 h2 失败回退的延迟与噪声)
	fetchH1 := func(method, url string, body io.Reader, hdr http.Header) (*http.Response, error) {
		req, err := http.NewRequest(method, url, body)
		if err != nil {
			return nil, err
		}
		setReqHeaders(req, hdr)
		return clientH1.Do(req)
	}

	// ★ 把 m3u8 里的相对 URI 解析成基于 m3u8 自身 URL 目录的绝对 CDN URL。
	//   原因: 页面 [net] 改写函数只匹配含 cctv.cn/yangshipin.cn 的 URL; 若 TS 分片是相对路径
	//   (如 2024078203_web-1757296101.ts), 浏览器会按页面 origin 127.0.0.1:18888/player/ 去取 → 404。
	//   改成绝对 CDN URL 后, 页面改写函数即可捕获并转发到 /media?u=..., 透明走代理。
	reURI := regexp.MustCompile(`URI="([^"]*)"`)
	rewriteM3U8 := func(body, m3u8URL string) string {
		base := m3u8URL
		// ★ 保留 base 的查询串 (svrtime/pid/ysign 等鉴权参数对 TS 分片同样需要):
		//   按 RFC3986 相对解析, 相对引用会继承 base 的 query, 故只在最后一个 '/' 处截断路径,
		//   其后的 ?query 自然保留。
		if i := strings.LastIndex(base, "/"); i >= 0 {
			base = base[:i+1]
		} else {
			base = ""
		}
		resolve := func(p string) string {
			if p == "" || strings.HasPrefix(p, "http://") || strings.HasPrefix(p, "https://") || strings.HasPrefix(p, "data:") {
				return p
			}
			if strings.HasPrefix(p, "/") { // 站点根相对
				if u2, err := url.Parse(m3u8URL); err == nil {
					return u2.Scheme + "://" + u2.Host + p
				}
				return p
			}
			return base + p
		}
		// 1) 独立行 (TS 分片 / 嵌套 m3u8)
		lines := strings.Split(body, "\n")
		for i, line := range lines {
			t := strings.TrimSpace(line)
			if t == "" || strings.HasPrefix(t, "#") {
				continue
			}
			lines[i] = resolve(t)
		}
		out := strings.Join(lines, "\n")
		// 2) 标签内 URI="..." (如 #EXT-X-KEY 解密 key、#EXT-X-MEDIA)
		out = reURI.ReplaceAllStringFunc(out, func(s string) string {
			m := reURI.FindStringSubmatch(s)
			if len(m) < 2 {
				return s
			}
			return `URI="` + resolve(m[1]) + `"`
		})
		return out
	}

	// ===== /media : 转发任意 URL (m3u8 / TS 分片 / 解密 key) =====
	//   WebView2 内的 hls.js 把所有媒体请求改写到 /media?u=<CDN URL>,
	//   由本代理用 utls Chrome 指纹抓取并回传, 规避 CDN 的 CORS / TLS 指纹限制。
	http.HandleFunc("/media", func(w http.ResponseWriter, r *http.Request) {
		addCors(w)
		if r.Method == "OPTIONS" {
			w.WriteHeader(204)
			return
		}
		u := r.URL.Query().Get("u")
		if u == "" {
			http.Error(w, "missing u", 400)
			return
		}
		// 调试日志已注释
		// log.Printf("MEDIA %s %s", r.Method, u)
		hdr := http.Header{}
		// ★ 关键: CDN m3u8/TS 请求需要 Referer, 否则可能 403 或返回非标准内容
		hdr.Set("Referer", "https://yangshipin.cn/")
		for _, h := range []string{"Range", "Accept", "Accept-Language", "Cookie"} {
			if v := r.Header.Get(h); v != "" {
				hdr.Set(h, v)
			}
		}
		resp, err := fetchH1(r.Method, u, r.Body, hdr)
		if err != nil {
			log.Printf("  MEDIA 代理抓取失败: %v", err)
			http.Error(w, err.Error(), 502)
			return
		}
		defer resp.Body.Close()
		ct := resp.Header.Get("Content-Type")
		uLower := strings.ToLower(u)
		isM3U8 := strings.Contains(ct, "mpegurl") || strings.Contains(ct, "vnd.apple") || strings.Contains(uLower, ".m3u8")
		// log.Printf("  MEDIA cdn-status=%d ct=%q len=%d m3u8=%v", resp.StatusCode, ct, resp.ContentLength, isM3U8)
		for k, vs := range resp.Header {
			for _, v := range vs {
				w.Header().Add(k, v)
			}
		}
		w.Header().Set("Access-Control-Allow-Origin", "*")
		// ★ 必须在 WriteHeader 之前删除上游 Content-Length: m3u8 改写后响应体长度变化,
		//   若保留旧长度会触发浏览器 ERR_CONTENT_LENGTH_MISMATCH → XHR status=0 → manifestLoadError。
		//   TS 分片为 1:1 拷贝、长度一致, 保留原始 Content-Length (含 206 Range 场景) 更稳妥。
		if isM3U8 {
			w.Header().Del("Content-Length")
		}
		w.WriteHeader(resp.StatusCode)
		if isM3U8 {
			// ★ 把相对 TS / key URI 改写成绝对 CDN URL, 使页面 [net] 改写能转发到 /media
			b, _ := io.ReadAll(resp.Body)
			// 调试日志已注释
			// head := strings.TrimSpace(string(b))
			// if len(head) > 120 { head = head[:120] }
			// log.Printf("  MEDIA m3u8 前120字: %s", head)
			_, _ = w.Write([]byte(rewriteM3U8(string(b), u)))
		} else {
			io.Copy(w, resp.Body)
		}
	})

	// ===== /sapi/ : 同源代理 sapi.yangshipin.cn (CMG 脚本 / worker) =====
	//   把 player.html 的 cmg 脚本与 worker 改为同源加载, 避免跨域 Worker 限制。
	//   同时把响应里的绝对 sapi URL 改写为 /sapi, 使内部引用也走同源。
	// ★ sapi 抓取: 先试 HTTP/2 (与 player-api 一致, yangshipin 基础设施要求 h2,
	//   用 h1 会被服务端直接断开 → 脚本 502 → Hls/CMGDecModule 未定义 → 不能播放)。
	//   失败再回退 h1。
	fetchSapi := func(method, url string, hdr http.Header) (*http.Response, error) {
		do := func(c *http.Client) (*http.Response, error) {
			req, e := http.NewRequest(method, url, nil)
			if e != nil {
				return nil, e
			}
			setReqHeaders(req, hdr)
			return c.Do(req)
		}
		if resp, e := do(clientH2); e == nil {
			return resp, nil
		} else {
			// 调试日志已注释
			// log.Printf("  SAPI h2 失败, 回退 h1: %v", e)
			return do(clientH1)
		}
	}

	http.HandleFunc("/sapi/", func(w http.ResponseWriter, r *http.Request) {
		addCors(w)
		if r.Method == "OPTIONS" {
			w.WriteHeader(204)
			return
		}
		rest := strings.TrimPrefix(r.URL.Path, "/sapi")
		if rest == "" {
			rest = "/"
		}
		u := "https://sapi.yangshipin.cn" + rest
		if r.URL.RawQuery != "" {
			u += "?" + r.URL.RawQuery
		}
		// ★ 磁盘缓存: 按路径缓存 (忽略 ver 查询, 内容相同), 避免每次重抓 CDN 偶发失败。
		//   缓存的是「原始上游内容」, 每次响应时再应用 URL 改写 + 注入, 使注入改动即时生效。
		exe, _ := os.Executable()
		cacheDir := filepath.Join(filepath.Dir(exe), "sapi_cache")
		cacheKey := strings.ReplaceAll(strings.Trim(rest, "/"), "/", "_")
		if cacheKey == "" {
			cacheKey = "root"
		}
		cachePath := filepath.Join(cacheDir, cacheKey)

		var body []byte
		var ct string
		if data, cerr := os.ReadFile(cachePath); cerr == nil {
			body = data
			ct = "application/javascript; charset=utf-8"
			// log.Printf("SAPI (cache) %s (%d bytes)", rest, len(body))
		} else {
			// log.Printf("SAPI %s %s", r.Method, u[:min(len(u), 120)])
			hdr := http.Header{}
			for _, h := range []string{"Accept", "Accept-Language", "Cookie"} {
				if v := r.Header.Get(h); v != "" {
					hdr.Set(h, v)
				}
			}
			resp, err := fetchSapi(r.Method, u, hdr)
			if err != nil {
				log.Printf("  SAPI 抓取失败: %v", err)
				http.Error(w, "sapi fetch failed: "+err.Error(), 502)
				return
			}
			defer resp.Body.Close()
			ct = resp.Header.Get("Content-Type")
			body, _ = io.ReadAll(resp.Body)
			if resp.StatusCode != 200 {
				// log.Printf("  SAPI 上游状态码 %d, len=%d", resp.StatusCode, len(body))
			} else {
				// 仅缓存 200 的成功响应
				os.MkdirAll(cacheDir, 0755)
				if werr := os.WriteFile(cachePath, body, 0644); werr == nil {
					// log.Printf("  SAPI 已缓存到 %s (%d bytes)", cachePath, len(body))
				} else {
					log.Printf("  SAPI 缓存写入失败: %v", werr)
				}
			}
		}
		// 把绝对 sapi URL 改写为 /sapi (同源), 涵盖 worker 等内部引用
		if strings.Contains(ct, "javascript") || strings.Contains(ct, "html") || strings.Contains(ct, "json") {
			body = []byte(strings.ReplaceAll(string(body), "https://sapi.yangshipin.cn", "/sapi"))
		}
		// ★★★ 诊断: 对 hls.cmg.js 的解密调用点注入日志, 确认 CMG 解密是否执行及参数/输出是否正确。
		//   解密调用: fG[wz(0x6bf)](module, config[0x291], jN[0x944], fG[0x9d2])
		//   包装为 IIFE: 记录 NALU type / 输入输出长度 / 首4字节(hex) / 时间戳 / mediaTagId / key类型。
		if strings.Contains(r.URL.Path, "hls.cmg.js") {
			// ★ 早装 wasm 包装器: 在 wasm 实例化时即包住 _CMG_* 导出, 以捕获 InitPlayer(懒包装会错过),
			//   并在 InitPlayer 前后 / 首个 UpdatePlayer 后扫描线性内存非零区块, diff 出密钥被写入的地址。
			const earlyWrap = `(function(){
  if(window.__cmgEarlyInstalled) return;
  window.__cmgEarlyInstalled = true;
  /* ★★ 调试日志已静默(0&&短路), 删除 0&& 即可恢复 ★★ */
  var PV = window.chrome && window.chrome.webview;
  function post(o){ try{ if(PV) PV.postMessage(o); }catch(e){} }
  0&&post({log:'[EARLY] installed'});
  function A(a){return typeof a==='number'?a:(typeof a==='string'?('"'+a.slice(0,24)+'"'):(a&&a.length!==undefined?('['+a.length+']'):typeof a));}
  function memOf(mod){
    try{
      if(mod&&mod.HEAPU8) return mod.HEAPU8;
      if(mod&&mod.asm&&mod.asm.memory) return new Uint8Array(mod.asm.memory.buffer);
      if(mod&&mod.wasmMemory) return new Uint8Array(mod.wasmMemory.buffer);
    }catch(e){}
    return null;
  }
  // 增量 diff 内存扫描: 只报相对上次的"新增/增长"块, 按地址升序, 截断到 600 字符
  var __memPrev = {};
  function snap(tag){
    try{
      var m=window.__cmgMod; if(!m) return;
      var u=memOf(m); if(!u) return;
      var cur={}; var cap=Math.min(u.length, 16*1024*1024);
      for(var off=0; off<cap; off+=4096){
        var nz=0; for(var k=off;k<off+4096&&k<u.length;k++){if(u[k]!==0){nz++;}}
        if(nz>0) cur[off]=nz;
      }
      var parts=[];
      for(var o in cur){
        var ov=+o, pv=__memPrev[ov];
        if(pv===undefined || cur[ov] > pv+8) parts.push('@'+ov+':nz'+cur[ov]+(pv!==undefined?('(+'+(cur[ov]-pv)+')'):''));
      }
      __memPrev = cur;
      parts.sort(function(a,b){return (+a.slice(1).split(':')[0]) - (+b.slice(1).split(':')[0]);});
      if(parts.length) post({log:'[MEM-DIFF] '+tag+' '+parts.join(' ').slice(0,600)});
      else post({log:'[MEM-DIFF] '+tag+' (no change)'});
    }catch(e){ post({log:'[MEM-ERR] '+e.message}); }
  }
  function wrapMod(mod){
    if(!mod||window.__cmgModWrapped) return;
    if(typeof mod._CMG_jsdecLive8!=='function') return;
    window.__cmgModWrapped=true;
    window.__cmgMod=mod;
    var orig={};
    ['_CMG_InitPlayer','_CMG_UnInitPlayer','_CMG_UpdatePlayer','_CMG_jsdecLive8'].forEach(function(n){
      if(typeof mod[n]==='function'){ orig[n]=mod[n]; }
    });
    function callOrig(n,args){ return orig[n].apply(mod,args); }
    // ★ 强制补调 InitPlayer: 派发器未把它路由到 wasm 导出, 导致密钥槽空→恒等.
    //   用 UpdatePlayer/jsdecLive8 共用的上下文指针(首参)作为 InitPlayer 的入参, 在首次 UpdatePlayer 前补调.
    function forceInit(ctx){
      if(window.__initForced) return;
      window.__initForced=1;
      var fn = orig._CMG_InitPlayer || (mod.asm&&mod.asm.ba);
      if(typeof fn!=='function'){ post({log:'[FORCE-INIT] 无 _CMG_InitPlayer 可用 (orig='+(typeof orig._CMG_InitPlayer)+',asm.ba='+(typeof (mod.asm&&mod.asm.ba))+')'}); return; }
      post({log:'[FORCE-INIT] 补调 _CMG_InitPlayer('+ctx+')'});
      snap('preForceInit');
      var rv; try{ rv=fn(ctx); }catch(e){ post({log:'[FORCE-INIT-ERR] '+e.message}); return; }
      post({log:'[FORCE-INIT] 返回='+A(rv)});
      snap('postForceInit');
    }
    mod._CMG_InitPlayer=function(){ if(!window.__initLog){window.__initLog=1;post({log:'[WASM-E] _CMG_InitPlayer('+Array.prototype.map.call(arguments,A).join(',')+')'});} return callOrig('_CMG_InitPlayer',arguments); };
    mod._CMG_UnInitPlayer=function(){ if(!window.__uninitLog){window.__uninitLog=1;post({log:'[WASM-E] _CMG_UnInitPlayer('+Array.prototype.map.call(arguments,A).join(',')+')'});} return callOrig('_CMG_UnInitPlayer',arguments); };
    mod._CMG_UpdatePlayer=function(){
      if(!window.__upd1){ window.__upd1=1; snap('preUpdate#1'); }
      window.__cmgCtxPtr = arguments[0];
      if((window.__updCnt=(window.__updCnt||0)+1)<=5) post({log:'[WASM-E] _CMG_UpdatePlayer('+Array.prototype.map.call(arguments,A).join(',')+')'});
      return callOrig('_CMG_UpdatePlayer',arguments);
    };
    mod._CMG_jsdecLive8=function(){
      if((window.__decN=(window.__decN||0)+1)<=5) post({log:'[WASM-E] _CMG_jsdecLive8('+Array.prototype.map.call(arguments,A).join(',')+')'});
      if(!window.__dec1){ window.__dec1=1; snap('postDec#1'); }
      return callOrig('_CMG_jsdecLive8',arguments);
    };
    post({log:'[WASM-WRAP] wrapped _CMG_* on CNTVH5PlayerModule'});
    snap('moduleReady');
  // ★ wasm 热修补 v3: 保存 6.3-6.7MB 所有非零 4KB 块 → 每 2s 对比并还原差异
  var __vmBlocks={},__vmReady=false;
  setTimeout(function(){
    try{
      var mod=window.CNTVH5PlayerModule;
      var u8=mod&&mod.HEAPU8||(mod&&mod.asm&&mod.asm.memory&&new Uint8Array(mod.asm.memory.buffer));
      if(!u8)return;
      var cap=Math.min(u8.length,6700000);
      var count=0;
      for(var off=6300000;off<cap;off+=4096){
        var nz=0;
        for(var k=off;k<off+4096&&k<u8.length;k++){if(u8[k]!==0)nz++;}
        if(nz>0){__vmBlocks[off]=new Uint8Array(u8.slice(off,off+4096));count++;}
      }
      __vmReady=true;
      if(window.chrome&&window.chrome.webview)
        window.chrome.webview.postMessage({log:"[VMPATCH3] saved "+count+" blocks"});
    }catch(e){}
  },6000);
  setInterval(function(){
    try{
      var mod=window.CNTVH5PlayerModule;
      var u8=mod&&mod.HEAPU8||(mod&&mod.asm&&mod.asm.memory&&new Uint8Array(mod.asm.memory.buffer));
      if(!u8||!__vmReady)return;
      var fixes=[],skipped=0;
      for(var off in __vmBlocks){
        var saved=__vmBlocks[off];
        var o=Number(off);
        // ★ 8K 安全: 跳过 diff>2KB 的块(可能是 wasm worker 当前活跃状态, 写回会与 worker 竞争)
        var diff=0;
        for(var k=0;k<4096&&o+k<u8.length;k++){if(u8[o+k]!==saved[k])diff++;}
        if(diff>2048){skipped++;continue;}
        if(diff>0){
          for(var k=0;k<4096&&o+k<u8.length;k++){if(u8[o+k]!==saved[k])u8[o+k]=saved[k];}
          fixes.push(off+':'+diff);
        }
      }
      if((fixes.length||skipped)&&window.chrome&&window.chrome.webview)
        window.chrome.webview.postMessage({log:"[VMPATCH3-FIX] "+fixes.length+" fix / "+skipped+" skip: "+fixes.join(" ").slice(0,200)});
    }catch(e){}
  },2000);  }
  // 轮询等待胶水 module 挂上 _CMG_* (wasm 实例化后才挂, 早于首次解密)
  var tries=0;
  var iv=setInterval(function(){
    tries++;
    var mod=window.CNTVH5PlayerModule;
    if(mod&&typeof mod._CMG_jsdecLive8==='function'){ clearInterval(iv); wrapMod(mod); }
    else if(tries>500){ clearInterval(iv); post({log:'[EARLY] timeout: CNTVH5PlayerModule._CMG_* 未出现 (mod='+(typeof mod)+')'}); }
  }, 10);
  // 实例级诊断: 仅记录每个 wasm 的原始导出名(确认解密 wasm 的 mangled 名), 不包装
  function instDiag(inst){
    try{
      var ex=inst&&inst.exports; if(!ex) return;
      var names=Object.keys(ex).filter(function(k){return typeof ex[k]==='function';});
      post({log:'[WASM-INST] exports: '+names.join(',').slice(0,400)});
    }catch(e){}
  }
  var OI=WebAssembly.Instance;
  WebAssembly.Instance=function(m,imp){ var i=new OI(m,imp); instDiag(i); return i; };
  WebAssembly.Instance.prototype=OI.prototype;
  var Oia=WebAssembly.instantiate;
  if(Oia) WebAssembly.instantiate=function(s,imp){
    var res=Oia.apply(this,arguments);
    if(res&&typeof res.then==='function'){ return res.then(function(r){ if(r&&r.instance) instDiag(r.instance); return r; }); }
    if(res&&res.instance) instDiag(res.instance);
    return res;
  };
  if(WebAssembly.instantiateStreaming){ var Oist=WebAssembly.instantiateStreaming; WebAssembly.instantiateStreaming=function(r,imp){ var res=Oist.apply(this,arguments); if(res&&typeof res.then==='function'){ return res.then(function(x){ if(x&&x.instance) instDiag(x.instance); return x; }); } return res; }; }
})()`
			body = append([]byte(earlyWrap), body...)
			// 路径1: 用全局 config[0x291](时间戳) + fG[0x9d2](常量key)
			const cmgDecOld = `fG[wz(0x6bf)](jJ[wz(0x97f)],jJ['config'][wz(0x291)],jN[wz(0x944)],fG[wz(0x9d2)])`
			// 路径2: 用 jJ[0xb0b][0x291](level/mediaTagId时间戳) + fG[0x22f](key)
			const cmgDecOld2 = `fG[wz(0x6bf)](jJ[wz(0x97f)],jJ[wz(0xb0b)][wz(0x291)],jN[wz(0x944)],fG[wz(0x22f)])`
			// ★ 节流: 仅记录 type=1(P/B)/type=5(IDR) 且最多 40 条。成功时 outh 应为合法 H264 NALU 头(65/41/61)。
			var cmgDecNew = `(function(__in){var __m=jJ[wz(0x97f)],__ts=jJ['config'][wz(0x291)],__k=fG[wz(0x9d2)],__mt=(jJ[wz(0xb0b)]&&jJ[wz(0xb0b)]['mediaTagId'])!=null?jJ[wz(0xb0b)]['mediaTagId']:'NULL';
			if(!window.__cmgWrapped&&__m){window.__cmgWrapped=true;window.__cmgCalls=[];function __arg(a){return typeof a==='number'?a:(typeof a==='string'?'\"'+a.substring(0,16)+'\"':(a&&a.length!==undefined?('['+a.length+']'):typeof a));}function __wrap(o,n){try{if(o&&typeof o[n]==='function'){var f=o[n];o[n]=function(){var __s=n+'('+Array.prototype.map.call(arguments,__arg).join(',')+')';try{window.__cmgCalls.push(__s);if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[WASM] '+__s});}catch(e){}return f.apply(this,arguments);};}}catch(e){}}['_CMG_InitPlayer','_CMG_UnInitPlayer','_CMG_UpdatePlayer','_CMG_jsdecLive0','_CMG_jsdecLive1','_CMG_jsdecLive2','_CMG_jsdecLive3','_CMG_jsdecLive4','_CMG_jsdecLive5','_CMG_jsdecLive6','_CMG_jsdecLive7','_CMG_jsdecLive8','_CMG_jsdecVOD0','_CMG_jsdecVOD1','_CMG_jsdecVOD2','_CMG_jsdecVOD3','_CMG_jsdecVOD4','_CMG_jsdecVOD5','_CMG_jsdecVOD6','_CMG_jsdecVOD7','_CMG_jsdecVOD8'].forEach(function(n){__wrap(__m,n);if(__m.asm)__wrap(__m.asm,n);});if(__m.asm){Object.getOwnPropertyNames(__m.asm).forEach(function(n){__wrap(__m.asm,n);});}['dynCall_v','dynCall_vi','dynCall_vii'].forEach(function(n){__wrap(__m,n);});}var __out=fG[wz(0x6bf)](__m,__ts,__in,__k);try{
  if(jN['type']===0x1){
    var __id=true;
    if(__out&&__in&&__out.length===__in.length){
      for(var __z=0;__z<0x100&&__z<__out.length;__z++){if(__out[__z]!==__in[__z]){__id=false;break;}}
    } else {__id=false;}
    if(__id){
      (window.__cmgPB=window.__cmgPB||{})[__mt]={jN:jN,__in:__in,__m:__m,__ts:__ts,__k:__k,__log:window.__cmgDecLog};
    } else {
      var __bf=(window.__cmgPB=window.__cmgPB||{})[__mt];
      if(__bf&&__bf.jN){
        try{
          var __fx=fG[wz(0x6bf)](__bf.__m,__bf.__ts,__bf.__in,__bf.__k);
          var __ok=false;
          if(__fx&&__fx.length===__bf.__in.length){
            for(var __z3=0;__z3<0x100&&__z3<__fx.length;__z3++){if(__fx[__z3]!==__bf.__in[__z3]){__ok=true;break;}}
          }
          if(__ok){
            var __ip=false;
            try{ if(__bf.jN[0x944]&&typeof __bf.jN[0x944].set==='function'&&__bf.jN[0x944].length===__fx.length){__bf.jN[0x944].set(__fx);__ip=true;} else {__bf.jN[0x944]=__fx;} }catch(e){}
            try{ if(__bf.jN['data']&&typeof __bf.jN['data'].set==='function'&&__bf.jN['data'].length===__fx.length){__bf.jN['data'].set(__fx);} else {__bf.jN['data']=__fx;} }catch(e){}
            if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[FIX-PB] 补解密成功 #'+__bf.__log+' len='+__fx.length+' inplace='+__ip});
          } else {
            if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[FIX-PB-FAIL] 仍恒等 #'+__bf.__log});
          }
          delete (window.__cmgPB)[__mt];
        }catch(e){}
      }
    }
  } else if(jN['type']===0x5){
    try{
      var __wd=(jN[0x944]&&jN[0x944].slice)?jN[0x944].slice(0x0):new Uint8Array([0x65,0x01,0x00,0x00,0x00,0x00,0x00,0x00]);
      try{__wd[0x0]=0x41;}catch(e){}
      var __wts1=(jJ['config']&&jJ['config'][wz(0x291)]!=null)?jJ['config'][wz(0x291)]:__ts;
      var __wts2=(jJ[wz(0xb0b)]&&jJ[wz(0xb0b)][wz(0x291)]!=null)?jJ[wz(0xb0b)][wz(0x291)]:__ts;
      try{fG[wz(0x6bf)](__m,__wts1,__wd,fG[wz(0x9d2)]);}catch(e){}
      try{fG[wz(0x6bf)](__m,__wts2,__wd,fG[wz(0x22f)]);}catch(e){}
      if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[WARM] primed P/B slots 479='+(!!jJ[wz(0x479)])});
    }catch(e){ if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[WARM-ERR] '+e.message}); }
    var __bf2=(window.__cmgPB=window.__cmgPB||{})[__mt];
    if(__bf2&&__bf2.jN){
      try{
        var __fx2=fG[wz(0x6bf)](__bf2.__m,__bf2.__ts,__bf2.__in,__bf2.__k);
        var __ok2=false;
        if(__fx2&&__fx2.length===__bf2.__in.length){
          for(var __z4=0;__z4<0x100&&__z4<__fx2.length;__z4++){if(__fx2[__z4]!==__bf2.__in[__z4]){__ok2=true;break;}}
        }
        if(__ok2){
          var __ip2=false;
          try{ if(__bf2.jN[0x944]&&typeof __bf2.jN[0x944].set==='function'&&__bf2.jN[0x944].length===__fx2.length){__bf2.jN[0x944].set(__fx2);__ip2=true;} else {__bf2.jN[0x944]=__fx2;} }catch(e){}
          try{ if(__bf2.jN['data']&&typeof __bf2.jN['data'].set==='function'&&__bf2.jN['data'].length===__fx2.length){__bf2.jN['data'].set(__fx2);} else {__bf2.jN['data']=__fx2;} }catch(e){}
          if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[FIX-PB] 补解密成功 #'+__bf2.__log+' len='+__fx2.length+' inplace='+__ip2});
        } else {
          if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[FIX-PB-FAIL] 仍恒等 #'+__bf2.__log});
        }
        delete (window.__cmgPB)[__mt];
      }catch(e){}
    }
  }
}catch(e){}try{if((jN['type']===0x5||jN['type']===0x1)){window.__cmgDecLog=(window.__cmgDecLog||0)+0x1;if(window.__cmgDecLog<=0x4B0){function __h(b,n){return b&&b.length>=n?Array.prototype.map.call(b.subarray(0x0,n),function(x){return('0'+x.toString(0x10)).slice(-0x2)}).join(''):'?';}function __eq(a,b){if(!a||!b||a.length!==b.length)return false;var __n=Math.min(a.length,0x100);for(var i=0;i<__n;i++)if(a[i]!==b[i])return false;return a.length===b.length;}function __kdesc(k){if(k==null)return 'null';if(typeof k==='string')return 'str('+k.length+')'+k.substring(0,40);if(k.length!==undefined)return (k.constructor&&k.constructor.name||'bytes')+'('+k.length+')'+__h(k,0x10);return typeof k;}function __fd(a,b){var r=[0,-1,-1];if(a&&b){var __mm=Math.min(a.length,b.length);for(var i=0;i<__mm;i++){if(a[i]!==b[i]){r[0]++;if(r[1]<0)r[1]=i;r[2]=i;}}}return r;}var __fdr=__fd(__out,__in);function __ent(b){if(!b||!b.length)return -1;var f=new Array(256).fill(0);for(var i=0;i<b.length;i++)f[b[i]]++;var e=0;for(var i=0;i<256;i++){if(f[i]){var pp=f[i]/b.length;e-=pp*Math.log2(pp);}}return e;}function __emu(b){if(!b)return -1;var c=0;for(var i=2;i<b.length;i++)if(b[i-2]===0&&b[i-1]===0&&b[i]===3)c++;return c;}var __same=(__fdr[0]===0&&__out.length===__in.length)?'Y':'N';var __L='CMGDEC1#'+window.__cmgDecLog+' t='+jN['type']+' in='+__in.length+' out='+__out.length+' same='+__same+' diffN='+__fdr[0]+' first='+__fdr[1]+' last='+__fdr[2]+' inh='+__h(__in,0x10)+' outh='+__h(__out,0x10)+' ts='+__ts+' ent_in='+__ent(__in).toFixed(2)+' ent_out='+__ent(__out).toFixed(2)+' emu_in='+__emu(__in)+' emu_out='+__emu(__out)+' mt='+__mt+' key='+__kdesc(__k);if(window.__cmgDecLog===0x1){__L+=' || A77='+__kdesc(fG[wz(0xa77)])+' || A8A='+__kdesc(fG[wz(0xa8a)])+' || B83='+__kdesc(fG[wz(0xb83)])+' || WASM='+(window.__cmgCalls.join(' ')||'NONE');try{var __cmds=[fG[wz(0xa77)],fG[wz(0xa8a)],fG[wz(0xb83)],'UPDATEPLAY','License','LICENSE','KEY','Init','init','Live','LIVE','PLAY','decLive'];var __seen={};var __res=[];for(var __ci=0;__ci<__cmds.length;__ci++){var __cmd=__cmds[__ci];if(__cmd==null||typeof __cmd!=='string'||__seen[__cmd])continue;__seen[__cmd]=1;try{fG[wz(0x909)](__m,__mt,__cmd);}catch(e){__res.push(__cmd+':E');continue;}try{var __o=fG[wz(0x6bf)](__m,__ts,__in,__k);__res.push(__cmd+':'+(__eq(__o,__in)?'Y':'N'));}catch(e){__res.push(__cmd+':dE');}}__L+=' || CMDINIT='+__res.join(',');}catch(e){__L+=' || CMDINITERR='+e.message;}}try{if(window.__cmgDecLog===0x1||(jN['type']===0x1&&window.__cmgDecLog===0x2)){var __holder=(__m&&__m.asm&&typeof __m.asm._CMG_jsdecLive8==='function')?__m.asm:(__m&&typeof __m._CMG_jsdecLive8==='function'?__m:null);if(__holder){var __sc=[];var __lbl=(window.__cmgDecLog===0x1?'IDR':'PB');var __orig=__holder._CMG_jsdecLive8;for(var __zi=0;__zi<=255;__zi++){__holder._CMG_jsdecLive8=function(a,b,c,d){return __orig.call(this,a,b,c,__zi);};var __o=null;try{__o=fG[wz(0x6bf)](__m,__ts,new Uint8Array(__in),__k);}catch(e){__o=null;}__holder._CMG_jsdecLive8=__orig;if(__o&&__o.length>0){var __d=0;var __mn=Math.min(__in.length,__o.length,0x100);for(var __di=0;__di<__mn;__di++){if(__o[__di]!==__in[__di])__d++;}if(__d>0){var __hh=[];for(var __hi=0;__hi<8;__hi++)__hh.push(('0'+__o[__hi].toString(0x10)).slice(-0x2));__sc.push(__zi+':N:'+__hh.join(''));}}}if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[KEYSCAN-'+__lbl+'] '+(__sc.length?__sc.join(' '):'ALL-Y')});}else{if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[KEYSCAN] NO_HOLDER'});}}}catch(e){if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[KEYSCAN-ERR] '+e.message});}if(jN['type']===0x1&&window.__cmgDecLog===0x2){try{var __forces=[0x65,0x67,0x27,0x47,0x41];var __fr=[];for(var __fi=0;__fi<__forces.length;__fi++){var __c=new Uint8Array(__in);__c[0]=__forces[__fi];var __o2=null;try{__o2=fG[wz(0x6bf)](__m,__ts,__c,__k);}catch(__e2){__o2=null;}if(__o2){var __d=0;var __mn=Math.min(__c.length,__o2.length,0x20);for(var __di=0;__di<__mn;__di++)if(__o2[__di]!==__c[__di])__d++;var __hh=[];for(var __hi=0;__hi<0x10;__hi++)__hh.push(('0'+__o2[__hi].toString(0x10)).slice(-0x2));__fr.push('h'+__forces[__fi].toString(0x10)+':'+((__o2.length!==__c.length||__d>0)?'N':'Y')+':d'+__d+':'+__hh.join(''));}else{__fr.push('h'+__forces[__fi].toString(0x10)+':NULL');}}__L+=' || FORCE='+__fr.join(' ');}catch(__fe){__L+=' || FORCEERR='+__fe.message;}}try{if(jN['type']===0x1&&window.__cmgDecLog===0x2){var __c2=[fG[wz(0x22f)],fG[wz(0x9d2)],'UpdatePlayer','update','Live','live','LIVE','play','Play','PLAY','start','Start','init','Init','InitPlayer','load','Load','key','Key','KEY','setKey','getKey','P','B','PB','pkey','bkey','pbkey','cmg','CMG','dec','Dec','decLive','decLive8','refresh','Refresh','sync','Sync','license','livekey','p_live','b_live','pb_live','KEYLIVE'];var __r2=[];for(var __i2=0;__i2<__c2.length;__i2++){var __cmd2=__c2[__i2];if(__cmd2==null)continue;try{fG[wz(0x909)](__m,__mt,__cmd2);}catch(e){__r2.push((typeof __cmd2==='string'?__cmd2:('['+__cmd2.length+']'))+':E');continue;}try{var __o2=fG[wz(0x6bf)](__m,__ts,new Uint8Array(__in),__k);var __d2=0;var __mn2=Math.min(__in.length,__o2.length,0x100);for(var __di2=0;__di2<__mn2;__di2++)if(__o2[__di2]!==__in[__di2])__d2++;__r2.push((typeof __cmd2==='string'?__cmd2:('['+__cmd2.length+']'))+':'+(__o2.length!==__in.length||__d2>0?'N':'Y'));}catch(e){__r2.push((typeof __cmd2==='string'?__cmd2:('['+__cmd2.length+']'))+':dE');}}try{fG[wz(0x909)](__m,__mt,fG[wz(0xa77)]);}catch(e){}__L+=' || PBKEYSCAN='+__r2.join(',');}}catch(e){__L+=' || PBKEYSCANERR='+e.message;}if(window.__cmgDecLog===0x2){__L+=' || WASM2='+(window.__cmgCalls.slice(0,80).join(' ')||'NONE');}if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:__L});}}}catch(e){}return __out;})(jN[wz(0x944)])`
		var cmgDecNew2 = `(function(__in){var __m=jJ[wz(0x97f)],__lvl=jJ[wz(0xb0b)]||{},__ts=__lvl[wz(0x291)],__k=fG[wz(0x22f)],__mt=(jJ[wz(0xb0b)]&&jJ[wz(0xb0b)]['mediaTagId'])!=null?jJ[wz(0xb0b)]['mediaTagId']:'NULL';var __out=fG[wz(0x6bf)](__m,__ts,__in,__k);try{
  if(jN['type']===0x1){
    var __id=true;
    if(__out&&__in&&__out.length===__in.length){
      for(var __z=0;__z<0x100&&__z<__out.length;__z++){if(__out[__z]!==__in[__z]){__id=false;break;}}
    } else {__id=false;}
    if(__id){
      (window.__cmgPB=window.__cmgPB||{})[__mt]={jN:jN,__in:__in,__m:__m,__ts:__ts,__k:__k,__log:window.__cmgDecLog};
    } else {
      var __bf=(window.__cmgPB=window.__cmgPB||{})[__mt];
      if(__bf&&__bf.jN){
        try{
          var __fx=fG[wz(0x6bf)](__bf.__m,__bf.__ts,__bf.__in,__bf.__k);
          var __ok=false;
          if(__fx&&__fx.length===__bf.__in.length){
            for(var __z3=0;__z3<0x100&&__z3<__fx.length;__z3++){if(__fx[__z3]!==__bf.__in[__z3]){__ok=true;break;}}
          }
          if(__ok){
            var __ip=false;
            try{ if(__bf.jN[0x944]&&typeof __bf.jN[0x944].set==='function'&&__bf.jN[0x944].length===__fx.length){__bf.jN[0x944].set(__fx);__ip=true;} else {__bf.jN[0x944]=__fx;} }catch(e){}
            try{ if(__bf.jN['data']&&typeof __bf.jN['data'].set==='function'&&__bf.jN['data'].length===__fx.length){__bf.jN['data'].set(__fx);} else {__bf.jN['data']=__fx;} }catch(e){}
            if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[FIX-PB] 补解密成功 #'+__bf.__log+' len='+__fx.length+' inplace='+__ip});
          } else {
            if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[FIX-PB-FAIL] 仍恒等 #'+__bf.__log});
          }
          delete (window.__cmgPB)[__mt];
        }catch(e){}
      }
    }
  } else if(jN['type']===0x5){
    try{
      var __wd=(jN[0x944]&&jN[0x944].slice)?jN[0x944].slice(0x0):new Uint8Array([0x65,0x01,0x00,0x00,0x00,0x00,0x00,0x00]);
      try{__wd[0x0]=0x41;}catch(e){}
      var __wts1=(jJ['config']&&jJ['config'][wz(0x291)]!=null)?jJ['config'][wz(0x291)]:__ts;
      var __wts2=(jJ[wz(0xb0b)]&&jJ[wz(0xb0b)][wz(0x291)]!=null)?jJ[wz(0xb0b)][wz(0x291)]:__ts;
      try{fG[wz(0x6bf)](__m,__wts1,__wd,fG[wz(0x9d2)]);}catch(e){}
      try{fG[wz(0x6bf)](__m,__wts2,__wd,fG[wz(0x22f)]);}catch(e){}
      if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[WARM] primed P/B slots 479='+(!!jJ[wz(0x479)])});
    }catch(e){ if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[WARM-ERR] '+e.message}); }
    var __bf2=(window.__cmgPB=window.__cmgPB||{})[__mt];
    if(__bf2&&__bf2.jN){
      try{
        var __fx2=fG[wz(0x6bf)](__bf2.__m,__bf2.__ts,__bf2.__in,__bf2.__k);
        var __ok2=false;
        if(__fx2&&__fx2.length===__bf2.__in.length){
          for(var __z4=0;__z4<0x100&&__z4<__fx2.length;__z4++){if(__fx2[__z4]!==__bf2.__in[__z4]){__ok2=true;break;}}
        }
        if(__ok2){
          var __ip2=false;
          try{ if(__bf2.jN[0x944]&&typeof __bf2.jN[0x944].set==='function'&&__bf2.jN[0x944].length===__fx2.length){__bf2.jN[0x944].set(__fx2);__ip2=true;} else {__bf2.jN[0x944]=__fx2;} }catch(e){}
          try{ if(__bf2.jN['data']&&typeof __bf2.jN['data'].set==='function'&&__bf2.jN['data'].length===__fx2.length){__bf2.jN['data'].set(__fx2);} else {__bf2.jN['data']=__fx2;} }catch(e){}
          if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[FIX-PB] 补解密成功 #'+__bf2.__log+' len='+__fx2.length+' inplace='+__ip2});
        } else {
          if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[FIX-PB-FAIL] 仍恒等 #'+__bf2.__log});
        }
        delete (window.__cmgPB)[__mt];
      }catch(e){}
    }
  }
}catch(e){}try{if((jN['type']===0x5||jN['type']===0x1)){window.__cmgDecLog=(window.__cmgDecLog||0)+0x1;if(window.__cmgDecLog<=0x4B0){function __h(b,n){return b&&b.length>=n?Array.prototype.map.call(b.subarray(0x0,n),function(x){return('0'+x.toString(0x10)).slice(-0x2)}).join(''):'?';}function __eq(a,b){if(!a||!b||a.length!==b.length)return false;var __n=Math.min(a.length,0x100);for(var i=0;i<__n;i++)if(a[i]!==b[i])return false;return a.length===b.length;}function __kdesc(k){if(k==null)return 'null';if(typeof k==='string')return 'str('+k.length+')'+k.substring(0,40);if(k.length!==undefined)return (k.constructor&&k.constructor.name||'bytes')+'('+k.length+')'+__h(k,0x10);return typeof k;}function __fd(a,b){var r=[0,-1,-1];if(a&&b){var __mm=Math.min(a.length,b.length);for(var i=0;i<__mm;i++){if(a[i]!==b[i]){r[0]++;if(r[1]<0)r[1]=i;r[2]=i;}}}return r;}var __fdr=__fd(__out,__in);var __same=(__fdr[0]===0&&__out.length===__in.length)?'Y':'N';var __L='CMGDEC2#'+window.__cmgDecLog+' t='+jN['type']+' in='+__in.length+' out='+__out.length+' same='+__same+' diffN='+__fdr[0]+' first='+__fdr[1]+' last='+__fdr[2]+' inh='+__h(__in,0x10)+' outh='+__h(__out,0x10)+' ts='+__ts+' mt='+__mt+' key='+__kdesc(__k);if(window.__cmgDecLog===0x1){try{var __mod=__m||window.CNTVH5PlayerModule;__L+=' || MOD='+(__mod?Object.getOwnPropertyNames(__mod).join('|'):'NULL');if(__mod&&__mod.exports)__L+=' || EXP='+Object.getOwnPropertyNames(__mod.exports).join('|');__L+=' || A77='+__kdesc(fG[wz(0xa77)]);var __lv=jJ[wz(0xb0b)];__L+=' || LVL='+(__lv?Object.getOwnPropertyNames(__lv).join('|'):'NULL');}catch(e){__L+=' || DUMPERR='+e.message;}}if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:__L});}}}catch(e){}return __out;})(jN[wz(0x944)])`
			// ★★ 诊断日志优化 (2026-07-16):
			//   1. 帧日志上限 40→1200 (0x4B0, ≈40秒@30fps), 足够覆盖30秒花屏窗口
			//   2. 过滤 __wrap 中 jsdecLive* 的 WASM 日志(KEYSCAN每帧256条=刷屏元凶)
			//   3. 限制 __wrap 每个函数只记前3次 WASM 日志(UpdatePlayer等不再无限刷屏)
			//   4. 每200帧输出紧凑健康行 [CMG] same/t/in/out/ts/inh/outh (方便定位花屏起始帧)
			cmgDecNew = strings.ReplaceAll(cmgDecNew, "window.__cmgDecLog<=0x28", "window.__cmgDecLog<=0x4B0")
			cmgDecNew2 = strings.ReplaceAll(cmgDecNew2, "window.__cmgDecLog<=0x28", "window.__cmgDecLog<=0x4B0")
			// 过滤 jsdecLive* WASM 日志 + 限制每个函数只记前3次
			cmgDecNew = strings.ReplaceAll(cmgDecNew,
				`if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[WASM] '+__s});`,
				`if(!/jsdecLive/i.test(n)&&(window.__cmgWCallCnt=(window.__cmgWCallCnt||{}),window.__cmgWCallCnt[n]=(window.__cmgWCallCnt[n]||0)+1)<=3&&window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[WASM] '+__s});`)
			cmgDecNew2 = strings.ReplaceAll(cmgDecNew2,
				`if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[WASM] '+__s});`,
				`if(!/jsdecLive/i.test(n)&&(window.__cmgWCallCnt=(window.__cmgWCallCnt||{}),window.__cmgWCallCnt[n]=(window.__cmgWCallCnt[n]||0)+1)<=3&&window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[WASM] '+__s});`)
			// 紧凑周期性健康检查: 首次60帧全量详情后, 每200帧输出1行紧凑摘要; same=Y 时总是输出
			cmgDecNew = strings.ReplaceAll(cmgDecNew,
				`window.__cmgDecLog=(window.__cmgDecLog||0)+0x1;`,
				`window.__cmgDecLog=(window.__cmgDecLog||0)+0x1;try{var __hcD=function(a,b){var r=[0,-1,-1];if(a&&b){var m=Math.min(a.length,b.length);for(var i=0;i<m;i++){if(a[i]!==b[i]){r[0]++;if(r[1]<0)r[1]=i;r[2]=i;}}}return r;};var __hcDr=__hcD(__out,__in);var __hcS=(__hcDr[0]===0&&__out.length===__in.length)?'Y':'N';var __hcH=function(b,n){var s='';try{for(var i=0;i<n&&i<b.length;i++)s+=('0'+b[i].toString(16)).slice(-2);}catch(e){}return s;};if(__hcS==='Y'||window.__cmgDecLog%0xC8===0||window.__cmgDecLog<=0x3C){if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[CMG] #'+window.__cmgDecLog+' same='+__hcS+' t='+jN.type+' in='+__in.length+' out='+__out.length+' diffN='+__hcDr[0]+' ts='+__ts+' inh='+__hcH(__in,16)+' outh='+__hcH(__out,16)});}}catch(e){}`)
			// KEYROT/REINIT 已移除: 实证会破坏 wasm 内部状态或引入难以控制的语法嵌套
			patched := strings.Replace(string(body), cmgDecOld, cmgDecNew, -1)
			patched = strings.Replace(patched, cmgDecOld2, cmgDecNew2, -1)
			// ★ 派发器探针: 记录 fG[0x909] 收到的每条命令/种子, 确认 InitPlayer 是否真的下发、jD(mediaTagId/ts) 与当时 location
			const dispProbeOld = `jB[wk(0x909)]=function(jC,jD,jE){var wl=wk`
			const dispProbeNew = `jB[wk(0x909)]=function(jC,jD,jE){try{if(window.chrome&&window.chrome.webview){var __jd=(typeof jD==='object'?(jD&&jD.length!==undefined?('['+jD.length+']'):(JSON.stringify(jD)||'').slice(0,120)):jD);var __loc=(self.location&&self.location.href)||'';0&&window.chrome.webview.postMessage({log:'[DISP] cmd='+jE+' jD='+__jd+' loc='+__loc.slice(0,90)});}}catch(e){}var wl=wk`
			if strings.Contains(patched, dispProbeOld) {
				patched = strings.Replace(patched, dispProbeOld, dispProbeNew, -1)
				// log.Printf("  [diag] 派发器探针已注入")
			} else {
				log.Printf("  [diag] WARN: 派发器探针未匹配")
			}
			// ★★★ 决定性探针 [DISP-INIT-BLOCK]: 把整个 InitPlayer 分支体(4 条赋值语句 + wasm 调用)
			//   整体替换为一个 try/catch 包裹、崩溃安全、逐语句记录的诊断版本。
			//   背景: 之前 InitPlayer  case 进了(ENTER 打了)但 _CMG_InitPlayer 从未执行、也无 THREW ——
			//   说明分支体内某条语句抛异常被外层 catch(jN){} 静默吞掉。本版本把真实异常打出来,
			//   并兜底 self['activeURL']/self[0x44c,0x466] 等可能为 undefined 的变量, 确保 wasm 调用必达。
			const initBlockOld = `self[jG(0x0,0x0,0x452,0x466)]=self[jG(0x0,0x0,0x450,0x46a)]||self[jG(0x0,0x0,0x43a,0x44a)][jG(0x0,0x0,0x463,0x471)]||window[jG(0x0,0x0,0x432,0x44a)][jG(0x0,0x0,0x461,0x471)]||window[jG(0x0,0x0,0x46e,0x46e)][jG(0x0,0x0,0x43a,0x44a)]||window[wl(0xb1d)][jG(0x0,0x0,0x454,0x454)]||'',jI[jG(0x0,0x0,0x46c,0x46d)](self[jG(0x0,0x0,0x44c,0x466)]['indexOf'](jG(0x0,0x0,0x45f,0x45d)),0x0)&&(self[jG(0x0,0x0,0x479,0x466)]=self['activeURL'][jG(0x0,0x0,0x46e,0x483)](jG(0x0,0x0,0x45f,0x45d),'')),self[jG(0x0,0x0,0x465,0x473)+jG(0x0,0x0,0x490,0x46b)]=!0x1,self[jG(0x0,0x0,0x461,0x44b)]='',jH=jC[jG(0x0,0x0,0x47b,0x461)+jG(0x0,0x0,0x459,0x44f)](jK)`
			const initBlockNew = `(function(){var __post=function(t){try{if(window.chrome&&window.chrome.webview)0&&window.chrome.webview.postMessage({log:t});}catch(e){}};try{0&&__post('[DISP-INIT-ENTER] InitPlayer case entered');}catch(e){}var __head=jG(0x0,0x0,0x450,0x46a);try{0&&__post('[DISP-INIT] head='+__head+' headVal='+(self[__head])+' activeURL='+(self['activeURL'])+' location='+(self.location&&self.location.href));}catch(e){}try{self[jG(0x0,0x0,0x465,0x473)+jG(0x0,0x0,0x490,0x46b)]=!0x1;}catch(e){}try{self[jG(0x0,0x0,0x461,0x44b)]='';}catch(e){}var __mn=jG(0x0,0x0,0x47b,0x461)+jG(0x0,0x0,0x459,0x44f);var __has=!!(jC&&typeof jC[__mn]==='function');var __r;try{__r=jC[__mn](jK);}catch(__e){try{0&&__post('[DISP-INIT] m='+__mn+' has='+__has+' THREW='+__e.message);}catch(_x){}throw __e;}try{0&&__post('[DISP-INIT] m='+__mn+' has='+__has+' ret='+__r);}catch(_x){}jH=__r;})()`
			if strings.Contains(patched, initBlockOld) {
				patched = strings.Replace(patched, initBlockOld, initBlockNew, -1)
				// log.Printf("  [diag] DISP-INIT-BLOCK 已注入(InitPlayer 分支整体包裹+崩溃安全)")
			} else {
				log.Printf("  [diag] WARN: DISP-INIT-BLOCK 未匹配")
			}
			if patched != string(body) {
				// log.Printf("  [diag] hls.cmg.js 解密调用已注入日志")
			} else {
				log.Printf("  [diag] WARN: 未匹配到解密调用点, 注入失败")
			}
			body = []byte(patched)
		}
		// ★★★ 根因修复: cmg.worker.js 的 emscripten Fetch 系统依赖 IndexedDB(Fetch.dbInstance)。
		//   emscripten fetch 默认走「先查 IndexedDB 缓存」模式, _emscripten_start_fetch 的首道门控:
		//     if((!c||IDB操作)&&!Fetch.dbInstance) return C(A),0;   // c=!!(16&flags)=REPLACE 标志
		//   在 WebView2 / http://127.0.0.1 环境下 IndexedDB 打开失败或异步未就绪 → dbInstance=false,
		//   门控 !Fetch.dbInstance 为真 → 直接 return 错误回调, 从不发 XHR →
		//   CMGPlayer.json(算法开关配置) 永不加载 → wasm 解密未初始化 → 恒等输出(same=Y) → 花屏。
		//   修复: dbInstance 缺失且非 IDB 存取操作时, 强制直接走网络 XHR(回调用 o, 不尝试写缓存),
		//   我们的 XHR patch 会把 CMGPlayer.json 请求 rewrite 到本地 /Library/CMGPlayer.json。
		// ★ 改为按 body 内容匹配 (更稳健, 不依赖请求路径), 只要含 IndexedDB 门控串就注入。
		if strings.Contains(string(body), "EM_IDB_STORE") {
			const fetchGateOld = `if((!c||"EM_IDB_STORE"===r||"EM_IDB_DELETE"===r)&&!Fetch.dbInstance)return C(A),0;`
			const fetchGateNew = `var __cmgRW=function(p){try{var u=UTF8ToString(p);if(/yangshipin\\.cn|cctv\\.cn/.test(u)&&u.indexOf('127.0.0.1')<0){var nu='http://127.0.0.1:18888/media?u='+encodeURIComponent(u);var b=[];for(var i=0;i<nu.length;i++)b.push(nu.charCodeAt(i));b.push(0);var np=_malloc(b.length);if(np){for(var j=0;j<b.length;j++)HEAPU8[np+j]=b[j];HEAPU32[p>>2]=np;return nu;}}}catch(e){}return null;};try{if(window.chrome&&window.chrome.webview){var __gu=HEAPU32[A+8>>2]?UTF8ToString(HEAPU32[A+8>>2]):'?';0&&window.chrome.webview.postMessage({log:'[FETCH-GATE] db='+(Fetch.dbInstance?1:0)+' r='+r+' c='+c+' u='+__gu.substring(0,160)});}}catch(_e){}if("EM_IDB_STORE"!==r&&"EM_IDB_DELETE"!==r){try{var __rw=__cmgRW(HEAPU32[A+8>>2]);if(window.chrome&&window.chrome.webview)0&&window.chrome.webview.postMessage({log:'[FETCH-FORCE] '+(__rw||__gu)});}catch(_e){}__emscripten_fetch_xhr(A,o,C,E,Q);return A}if((!c||"EM_IDB_STORE"===r||"EM_IDB_DELETE"===r)&&!Fetch.dbInstance)return C(A),0;`
			wp := strings.Replace(string(body), fetchGateOld, fetchGateNew, 1)
			if wp != string(body) {
				// log.Printf("  [diag] cmg.worker.js Fetch 门控已注入 (绕过 IndexedDB → 强制 XHR) path=%s", r.URL.Path)
			} else {
				log.Printf("  [diag] WARN: cmg.worker.js Fetch 门控未匹配, 注入失败 path=%s", r.URL.Path)
			}
			body = []byte(wp)
		}
		// ★ 关键修复: 禁止 WebView2 磁盘缓存 /sapi 脚本。
		//   否则浏览器会命中旧版 (无注入) 的 cmg.worker.js/hls.cmg.js 缓存,
		//   代理永远收不到请求, 注入的诊断代码永不生效。

		// ★★★ 彻底注释 JS 内嵌的 postMessage 日志（所有调试输出）
		patched := string(body)
		// 短路所有直接调用 window.chrome.webview.postMessage
		patched = strings.ReplaceAll(patched, "window.chrome.webview.postMessage", "0&&window.chrome.webview.postMessage")
		// 短路所有 post({log: ...}) 调用（仅匹配以 post({log: 开头的）
		patched = strings.ReplaceAll(patched, "post({log:", "0&&post({log:")
		body = []byte(patched)

		if ct != "" {
			w.Header().Set("Content-Type", ct)
		}
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
		w.Header().Set("Pragma", "no-cache")
		w.WriteHeader(200)
		w.Write(body)
	})

	// ===== /Library/CMGPlayer.json : 返回本地 CMG 播放器配置文件 =====
	//   cmg.worker.js 的 wasm 内部会 fetch 此 JSON 作为解密开关/配置来源。
	//   在本地同源环境中, 请求可能落到 http://127.0.0.1:18888/Library/CMGPlayer.json,
	//   故由本代理直接返回, 避免 404 导致 wasm 解密未初始化(恒等)。
	http.HandleFunc("/Library/CMGPlayer.json", func(w http.ResponseWriter, r *http.Request) {
		addCors(w)
		if r.Method == "OPTIONS" {
			w.WriteHeader(204)
			return
		}
		p := findCMGPlayerJSON()
		if p == "" {
			log.Printf("CMGPlayer.json 未找到")
			http.Error(w, "CMGPlayer.json not found", 404)
			return
		}
		data, err := os.ReadFile(p)
		if err != nil {
			log.Printf("CMGPlayer.json 读取失败: %v (path=%s)", err, p)
			http.Error(w, "CMGPlayer.json read failed: "+err.Error(), 500)
			return
		}
		// log.Printf("CMGPlayer.json 已返回 (path=%s, %d bytes)", p, len(data))
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
		w.Header().Set("Pragma", "no-cache")
		w.WriteHeader(200)
		w.Write(data)
	})

	// ===== /player : 同源托管注入后的 player.html =====
	//   C# 把注入了 wasm/cKey/yspticket base64 的 HTML 写到 player.served.html,
	//   WebView2 导航到 http://127.0.0.1:18888/player, 与 /media /sapi 同源。
	http.HandleFunc("/player", func(w http.ResponseWriter, r *http.Request) {
		addCors(w)
		exe, _ := os.Executable()
		p := filepath.Join(filepath.Dir(exe), "player.served.html")
		data, err := os.ReadFile(p)
		if err != nil {
			http.Error(w, "player.served.html 未找到: "+err.Error(), 404)
			return
		}
		// ★ 缓存破坏: 把脚本 URL 的固定 ?ver=250813 改成每次不同的时间戳,
		//   改变 HTTP 缓存键, 强制浏览器重新向 /sapi 拉取 (从而应用注入的诊断代码)。
		//   同时本响应也加 no-store, 防止 player.served.html 本身被缓存。
		html := string(data)
		verStamp := strconv.FormatInt(time.Now().UnixNano(), 10)
		html = strings.ReplaceAll(html, "ver=250813", "ver="+verStamp)
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
		w.Header().Set("Pragma", "no-cache")
		w.Write([]byte(html))
	})

	// ===== /open-token : GET h5access.yangshipin.cn/web/open/token =====
	http.HandleFunc("/open-token", func(w http.ResponseWriter, r *http.Request) {
		addCors(w)
		url := "https://" + openTokenHost + "/web/open/token" + "?" + r.URL.RawQuery
		proxyReq, _ := http.NewRequest("GET", url, nil)
		setReqHeaders(proxyReq, nil)
		proxyReq.Header.Set("Accept", "*/*")
		resp, err := clientH2.Do(proxyReq)
		if err != nil {
			http.Error(w, err.Error(), 502)
			return
		}
		defer resp.Body.Close()
		respBody, _ := io.ReadAll(resp.Body)
		// log.Printf("open-token HTTP %d (%db): %s", resp.StatusCode, len(respBody), string(respBody)[:min(len(respBody), 120)])
		w.Header().Set("Content-Type", "application/json;charset=UTF-8")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.WriteHeader(resp.StatusCode)
		w.Write(respBody)
	})

	// ===== /capi/ : 代理 capi.yangshipin.cn (EPG 节目单 protobuf → JSON) =====
	var capiHost = "capi.yangshipin.cn"

	http.HandleFunc("/capi/", func(w http.ResponseWriter, r *http.Request) {
		addCors(w)
		if r.Method == "OPTIONS" {
			w.WriteHeader(204)
			return
		}
		rest := strings.TrimPrefix(r.URL.Path, "/capi")
		u := "https://" + capiHost + rest
		if r.URL.RawQuery != "" {
			u += "?" + r.URL.RawQuery
		}
		proxyReq, _ := http.NewRequest(r.Method, u, r.Body)
		setReqHeaders(proxyReq, nil)
		proxyReq.Header.Set("Accept", "application/json, text/plain, */*")
		for _, h := range []string{"Accept-Language", "Cookie"} {
			if v := r.Header.Get(h); v != "" {
				proxyReq.Header.Set(h, v)
			}
		}
		resp, err := clientH1.Do(proxyReq)
		if err != nil {
			log.Printf("CAPI 代理失败: %v", err)
			http.Error(w, err.Error(), 502)
			return
		}
		defer resp.Body.Close()
		respBody, _ := io.ReadAll(resp.Body)

		// ★ EPG protobuf → JSON 解码: capi 返回 application/octet-stream (protobuf),
		//   字段: [1]total(varint) [2]programs(repeated) → program: [1]id [2]title [5]start [6]end [7]dur
		var jsonParts []string
		data := respBody
		off := 0
		for off < len(data) {
			tag, n := readVarint(data[off:])
			off += n
			fnum, wtype := int(tag>>3), int(tag&0x7)
			if wtype == 0 { // varint
				_, n := readVarint(data[off:])
				off += n
				if fnum == 1 { // total — skip
				}
			} else if wtype == 2 { // length-delimited
				length, ln := readVarint(data[off:])
				off += ln
				sub := data[off : off+int(length)]
				off += int(length)
				if fnum == 2 { // program message
					prog := parseEpgProgram(sub)
					if prog != "" {
						jsonParts = append(jsonParts, prog)
					}
				}
			} else {
				break
			}
		}
		jsonOut := "[" + strings.Join(jsonParts, ",") + "]"
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.WriteHeader(200)
		w.Write([]byte(jsonOut))
	})

	// ===== / : player-api 代理 (auth / get-live-info / health) =====
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		addCors(w)
		if r.Method == "OPTIONS" {
			w.WriteHeader(204)
			return
		}
		// /open-token 特殊路由已单独注册, 此处不再处理
		apiPath, ok := pathMap[r.URL.Path]
		if !ok {
			http.Error(w, "unknown path", 404)
			return
		}
		if r.URL.Path == "/health" {
			fmt.Fprint(w, "OK")
			return
		}

		body, _ := io.ReadAll(r.Body)
		r.Body.Close()

		url := "https://" + targetHost + apiPath
		proxyReq, _ := http.NewRequest("POST", url, bytes.NewReader(body))
		setReqHeaders(proxyReq, nil)
		proxyReq.Header.Set("Accept", "application/json, text/plain, */*")
		proxyReq.Header.Set("Accept-Language", "zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7")
		proxyReq.Header.Set("Cache-Control", "no-cache")
		proxyReq.Header.Set("Pragma", "no-cache")
		proxyReq.Header.Set("Priority", "u=1, i")
		proxyReq.Header.Set("Sec-Ch-Ua", `"Not;A=Brand";v="8", "Chromium";v="150", "Google Chrome";v="150"`)
		proxyReq.Header.Set("Sec-Ch-Ua-Mobile", "?0")
		proxyReq.Header.Set("Sec-Ch-Ua-Platform", `"Windows"`)
		proxyReq.Header.Set("Sec-Fetch-Dest", "empty")
		proxyReq.Header.Set("Sec-Fetch-Mode", "cors")
		proxyReq.Header.Set("Sec-Fetch-Site", "same-site")

		// ★ 强制 Content-Type: auth 必须是 form-urlencoded, get-live-info 是 json
		ct := r.Header.Get("Content-Type")
		if ct == "" || strings.Contains(ct, "text/plain") {
			ct = "application/x-www-form-urlencoded;charset=UTF-8"
		}
		proxyReq.Header.Set("Content-Type", ct)

		for _, h := range []string{
			"yspappid", "yspplayertoken",
			"yspsdkinput", "yspsdksign", "yspticket",
			"request-id", "seqid",
		} {
			if v := r.Header.Get(h); v != "" {
				proxyReq.Header.Set(h, v)
			}
		}
		// 转发 Cookie（HAR 中 auth 与 live 请求都包含 cookie）
		if ck := r.Header.Get("Cookie"); ck != "" {
			proxyReq.Header.Set("Cookie", ck)
		}

		// 调试日志已注释
		// log.Printf("POST %s (%db)", url, len(body))
		// log.Printf("  Body: %s", string(body))
		// log.Printf("  UA: %s", proxyReq.UserAgent())
		// for k, vs := range proxyReq.Header {
		// 	for _, v := range vs {
		// 		if len(v) > 80 {
		// 			log.Printf("  Hdr %s: %s...(truncated %d)", k, v[:80], len(v))
		// 		} else {
		// 			log.Printf("  Hdr %s: %s", k, v)
		// 		}
		// 	}
		// }
		resp, err := clientH2.Do(proxyReq)
		if err != nil {
			log.Printf("ERR: %v", err)
			http.Error(w, fmt.Sprintf(`{"code":-1,"msg":"%v"}`, err), 502)
			return
		}
		defer resp.Body.Close()

		respBody, _ := io.ReadAll(resp.Body)
		// if len(respBody) > 400 {
		// 	log.Printf("HTTP %d (%db): %s...", resp.StatusCode, len(respBody), respBody[:400])
		// } else {
		// 	log.Printf("HTTP %d (%db): %s", resp.StatusCode, len(respBody), respBody)
		// }

		w.Header().Set("Content-Type", "application/json;charset=UTF-8")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.WriteHeader(resp.StatusCode)
		w.Write(respBody)
	})

	// log.Printf("cctv-proxy (h2+utls Chrome 150, +/media /sapi /player) :%s", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}