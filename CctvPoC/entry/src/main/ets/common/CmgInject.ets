/**
 * CmgInject - /sapi 脚本的运行时注入常量（自动从 hmos/proxy/main.go 提取，勿手改）。
 * 生成：node hmos/proxy/_extract_inject.mjs
 */

export const earlyWrap = `(function(){
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
    if(!mod) return;
    if(typeof mod._CMG_jsdecLive8!=='function') return;
    // ★ 切台重建模块(2026-08-15): 允许重新 wrap 新模块(模块引用变了或 __cmgModWrapped 被清零时)
    if(window.__cmgMod && window.__cmgMod === mod && window.__cmgModWrapped) return;
    window.__cmgModWrapped=true;
    window.__cmgMod=mod;
    var orig={};
    ['_CMG_InitPlayer','_CMG_UnInitPlayer','_CMG_UpdatePlayer','_CMG_jsdecLive8'].forEach(function(n){
      if(typeof mod[n]==='function'){ orig[n]=mod[n]; }
    });
    function callOrig(n,args){ return orig[n].apply(mod,args); }
    // 不再从 JS 侧猜测上下文指针补调 InitPlayer；官方派发器负责建立完整的密钥上下文。
    // 直接补调会跳过种子 URL 和内部前置步骤，反而可能让首片使用空密钥。
    // ★ 切频道(2026-08-15): 外部入口, 按新频道种子重置 CMG 播放上下文。
    //   根因: 密钥表在 InitPlayer 时由 self['activeURL'](含 pid)派生; 切频道只换 m3u8 不换种子,
    //   新频道视频仍用旧频道密钥解密 → 花屏/绿屏(音频 AAC 不经视频解密 → 声音正常)。
    //   ★ v2(2026-08-15 晚) 修复实机「切台后卡住像暂停 / 再切台卡获取播放信息」:
    //     旧版先 _CMG_UnInitPlayer(旧ctx) 释放模块内部解码资源, 但 hls.js demux 构造器早已把
    //     CNTVH5PlayerModule 绑定为 jF[0x97f] 并持续调用 jsdecLive8 → 访问已释放状态 → wasm 主线程
    //     死锁 → 画面+声音全停(像暂停); 主线程被占死后 Index.ets 的 runJavaScript 全部挂起 → 后续
    //     切台卡在「获取播放信息…」。故切频道**不做 UnInit**, 仅解锁 __initForced 并重新 InitPlayer
    //     (同一 ctx), 让密钥表按 __setChannelSeed 已刷新的新 activeURL 重派生, 模块/ctx 引用保持有效。
    window.__cmgResetPlayer = function(){
      try{
        if(window.__cmgModWrapped!==true) return 'not-wrapped';
        var ctx = window.__cmgCtxPtr;
        if(!ctx){ window.__initForced = 0; return 'no-ctx(已解锁)'; }
        var log=[];
        log.push('noUnInit');
        window.__initForced = 0;
        window.__cmgResetCount=(window.__cmgResetCount||0)+1;
        var fn = orig._CMG_InitPlayer || (mod.asm&&mod.asm.ba);
        if(typeof fn==='function'){
          try{ var rv=fn(ctx); log.push('init='+A(rv)); }
          catch(e){ log.push('init-ERR:'+e.message); }
        } else { log.push('init=none'); }
        post({log:'[CMG-RESET] #'+window.__cmgResetCount+' '+log.join(' | ')});
        return log.join('|');
      }catch(e){ post({log:'[CMG-RESET-ERR] '+e.message}); return 'err:'+e.message; }
    };
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
  var __vmT1=setTimeout(function(){
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
  var __vmT2=setInterval(function(){
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
  },2000);
  // ★ 切台重建模块: 记录定时器 id, 重建时由 __cmgRebuild 清理(旧模块的内存基准不适用于新模块, 否则会错误还原)
  if(!window.__vmTimers) window.__vmTimers=[];
  window.__vmTimers.push(__vmT1,__vmT2);  }
  // 轮询等待胶水 module 挂上 _CMG_* (wasm 实例化后才挂, 早于首次解密)
  // ★ 切台重建(2026-08-15): 持续轮询(不一次性), 检测 CNTVH5PlayerModule 引用变化(重建后的新模块)即重新 wrap。
  var lastMod=null;
  var tries=0;
  var iv=setInterval(function(){
    tries++;
    var mod=window.CNTVH5PlayerModule;
    if(mod&&mod!==lastMod&&typeof mod._CMG_jsdecLive8==='function'){
      lastMod=mod;
      wrapMod(mod);
    }
    else if(tries===2000){ post({log:'[EARLY] 注意: 首次 wrap 等待超过 ~20s (mod='+(typeof mod)+')，继续轮询'}); }
  }, 10);
  // ★★ 2026-08-30 修复：原先是 tries>2000 → clearInterval(iv)，轮询会自杀。
  //    setInterval 在解码负载下漂移（实测 ~12ms/次），2000 次 ≈ 24s 后轮询死亡，
  //    此后每次换台的新模块都拿不到诊断包装 → 日志从某次换台起永久 wrapper-missing
  //    （实测：第 6 次换台仍 wrapper:true，第 7 次起全部 missing）。
  //    改为永不自杀：单次回调只是几个 typeof 判断，开销可忽略。
  //    影响面：wrapper 仅提供诊断与 __cmgCtxPtr 采集（__cmgResetPlayer 已无调用方），
  //    不影响播放——但丢了 CMG 解密诊断会给日后排查绿屏/花屏造成困难，故修复。
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
})()`;

export const cmgDecOld = `fG[wz(0x6bf)](jJ[wz(0x97f)],jJ['config'][wz(0x291)],jN[wz(0x944)],fG[wz(0x9d2)])`;

export const cmgDecOld2 = `fG[wz(0x6bf)](jJ[wz(0x97f)],jJ[wz(0xb0b)][wz(0x291)],jN[wz(0x944)],fG[wz(0x22f)])`;

export const cmgDecNew = `(function(__in){var __m=jJ[wz(0x97f)],__ts=jJ['config'][wz(0x291)],__k=fG[wz(0x9d2)],__mt=(jJ[wz(0xb0b)]&&jJ[wz(0xb0b)]['mediaTagId'])!=null?jJ[wz(0xb0b)]['mediaTagId']:'NULL';
			if(!window.__cmgWrapped&&__m){window.__cmgWrapped=true;window.__cmgCalls=[];function __arg(a){return typeof a==='number'?a:(typeof a==='string'?'\\"'+a.substring(0,16)+'\\"':(a&&a.length!==undefined?('['+a.length+']'):typeof a));}function __wrap(o,n){try{if(o&&typeof o[n]==='function'){var f=o[n];o[n]=function(){var __s=n+'('+Array.prototype.map.call(arguments,__arg).join(',')+')';try{window.__cmgCalls.push(__s);if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[WASM] '+__s});}catch(e){}return f.apply(this,arguments);};}}catch(e){}}['_CMG_InitPlayer','_CMG_UnInitPlayer','_CMG_UpdatePlayer','_CMG_jsdecLive0','_CMG_jsdecLive1','_CMG_jsdecLive2','_CMG_jsdecLive3','_CMG_jsdecLive4','_CMG_jsdecLive5','_CMG_jsdecLive6','_CMG_jsdecLive7','_CMG_jsdecLive8','_CMG_jsdecVOD0','_CMG_jsdecVOD1','_CMG_jsdecVOD2','_CMG_jsdecVOD3','_CMG_jsdecVOD4','_CMG_jsdecVOD5','_CMG_jsdecVOD6','_CMG_jsdecVOD7','_CMG_jsdecVOD8'].forEach(function(n){__wrap(__m,n);if(__m.asm)__wrap(__m.asm,n);});if(__m.asm){Object.getOwnPropertyNames(__m.asm).forEach(function(n){__wrap(__m.asm,n);});}['dynCall_v','dynCall_vi','dynCall_vii'].forEach(function(n){__wrap(__m,n);});}var __out=fG[wz(0x6bf)](__m,__ts,__in,__k);try{
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
}catch(e){}try{if((jN['type']===0x5||jN['type']===0x1)){window.__cmgDecLog=(window.__cmgDecLog||0)+0x1;if(window.__cmgDecLog<=0x4B0){function __h(b,n){return b&&b.length>=n?Array.prototype.map.call(b.subarray(0x0,n),function(x){return('0'+x.toString(0x10)).slice(-0x2)}).join(''):'?';}function __eq(a,b){if(!a||!b||a.length!==b.length)return false;var __n=Math.min(a.length,0x100);for(var i=0;i<__n;i++)if(a[i]!==b[i])return false;return a.length===b.length;}function __kdesc(k){if(k==null)return 'null';if(typeof k==='string')return 'str('+k.length+')'+k.substring(0,40);if(k.length!==undefined)return (k.constructor&&k.constructor.name||'bytes')+'('+k.length+')'+__h(k,0x10);return typeof k;}function __fd(a,b){var r=[0,-1,-1];if(a&&b){var __mm=Math.min(a.length,b.length);for(var i=0;i<__mm;i++){if(a[i]!==b[i]){r[0]++;if(r[1]<0)r[1]=i;r[2]=i;}}}return r;}var __fdr=__fd(__out,__in);function __ent(b){if(!b||!b.length)return -1;var f=new Array(256).fill(0);for(var i=0;i<b.length;i++)f[b[i]]++;var e=0;for(var i=0;i<256;i++){if(f[i]){var pp=f[i]/b.length;e-=pp*Math.log2(pp);}}return e;}function __emu(b){if(!b)return -1;var c=0;for(var i=2;i<b.length;i++)if(b[i-2]===0&&b[i-1]===0&&b[i]===3)c++;return c;}var __same=(__fdr[0]===0&&__out.length===__in.length)?'Y':'N';var __L='CMGDEC1#'+window.__cmgDecLog+' t='+jN['type']+' in='+__in.length+' out='+__out.length+' same='+__same+' diffN='+__fdr[0]+' first='+__fdr[1]+' last='+__fdr[2]+' inh='+__h(__in,0x10)+' outh='+__h(__out,0x10)+' ts='+__ts+' ent_in='+__ent(__in).toFixed(2)+' ent_out='+__ent(__out).toFixed(2)+' emu_in='+__emu(__in)+' emu_out='+__emu(__out)+' mt='+__mt+' key='+__kdesc(__k);if(window.__cmgDecLog===0x1){__L+=' || A77='+__kdesc(fG[wz(0xa77)])+' || A8A='+__kdesc(fG[wz(0xa8a)])+' || B83='+__kdesc(fG[wz(0xb83)])+' || WASM='+(window.__cmgCalls.join(' ')||'NONE');try{var __cmds=[fG[wz(0xa77)],fG[wz(0xa8a)],fG[wz(0xb83)],'UPDATEPLAY','License','LICENSE','KEY','Init','init','Live','LIVE','PLAY','decLive'];var __seen={};var __res=[];for(var __ci=0;__ci<__cmds.length;__ci++){var __cmd=__cmds[__ci];if(__cmd==null||typeof __cmd!=='string'||__seen[__cmd])continue;__seen[__cmd]=1;try{fG[wz(0x909)](__m,__mt,__cmd);}catch(e){__res.push(__cmd+':E');continue;}try{var __o=fG[wz(0x6bf)](__m,__ts,__in,__k);__res.push(__cmd+':'+(__eq(__o,__in)?'Y':'N'));}catch(e){__res.push(__cmd+':dE');}}__L+=' || CMDINIT='+__res.join(',');}catch(e){__L+=' || CMDINITERR='+e.message;}}try{if(window.__cmgDecLog===0x1||(jN['type']===0x1&&window.__cmgDecLog===0x2)){var __holder=(__m&&__m.asm&&typeof __m.asm._CMG_jsdecLive8==='function')?__m.asm:(__m&&typeof __m._CMG_jsdecLive8==='function'?__m:null);if(__holder){var __sc=[];var __lbl=(window.__cmgDecLog===0x1?'IDR':'PB');var __orig=__holder._CMG_jsdecLive8;for(var __zi=0;__zi<=255;__zi++){__holder._CMG_jsdecLive8=function(a,b,c,d){return __orig.call(this,a,b,c,__zi);};var __o=null;try{__o=fG[wz(0x6bf)](__m,__ts,new Uint8Array(__in),__k);}catch(e){__o=null;}__holder._CMG_jsdecLive8=__orig;if(__o&&__o.length>0){var __d=0;var __mn=Math.min(__in.length,__o.length,0x100);for(var __di=0;__di<__mn;__di++){if(__o[__di]!==__in[__di])__d++;}if(__d>0){var __hh=[];for(var __hi=0;__hi<8;__hi++)__hh.push(('0'+__o[__hi].toString(0x10)).slice(-0x2));__sc.push(__zi+':N:'+__hh.join(''));}}}if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[KEYSCAN-'+__lbl+'] '+(__sc.length?__sc.join(' '):'ALL-Y')});}else{if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[KEYSCAN] NO_HOLDER'});}}}catch(e){if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[KEYSCAN-ERR] '+e.message});}if(jN['type']===0x1&&window.__cmgDecLog===0x2){try{var __forces=[0x65,0x67,0x27,0x47,0x41];var __fr=[];for(var __fi=0;__fi<__forces.length;__fi++){var __c=new Uint8Array(__in);__c[0]=__forces[__fi];var __o2=null;try{__o2=fG[wz(0x6bf)](__m,__ts,__c,__k);}catch(__e2){__o2=null;}if(__o2){var __d=0;var __mn=Math.min(__c.length,__o2.length,0x20);for(var __di=0;__di<__mn;__di++)if(__o2[__di]!==__c[__di])__d++;var __hh=[];for(var __hi=0;__hi<0x10;__hi++)__hh.push(('0'+__o2[__hi].toString(0x10)).slice(-0x2));__fr.push('h'+__forces[__fi].toString(0x10)+':'+((__o2.length!==__c.length||__d>0)?'N':'Y')+':d'+__d+':'+__hh.join(''));}else{__fr.push('h'+__forces[__fi].toString(0x10)+':NULL');}}__L+=' || FORCE='+__fr.join(' ');}catch(__fe){__L+=' || FORCEERR='+__fe.message;}}try{if(jN['type']===0x1&&window.__cmgDecLog===0x2){var __c2=[fG[wz(0x22f)],fG[wz(0x9d2)],'UpdatePlayer','update','Live','live','LIVE','play','Play','PLAY','start','Start','init','Init','InitPlayer','load','Load','key','Key','KEY','setKey','getKey','P','B','PB','pkey','bkey','pbkey','cmg','CMG','dec','Dec','decLive','decLive8','refresh','Refresh','sync','Sync','license','livekey','p_live','b_live','pb_live','KEYLIVE'];var __r2=[];for(var __i2=0;__i2<__c2.length;__i2++){var __cmd2=__c2[__i2];if(__cmd2==null)continue;try{fG[wz(0x909)](__m,__mt,__cmd2);}catch(e){__r2.push((typeof __cmd2==='string'?__cmd2:('['+__cmd2.length+']'))+':E');continue;}try{var __o2=fG[wz(0x6bf)](__m,__ts,new Uint8Array(__in),__k);var __d2=0;var __mn2=Math.min(__in.length,__o2.length,0x100);for(var __di2=0;__di2<__mn2;__di2++)if(__o2[__di2]!==__in[__di2])__d2++;__r2.push((typeof __cmd2==='string'?__cmd2:('['+__cmd2.length+']'))+':'+(__o2.length!==__in.length||__d2>0?'N':'Y'));}catch(e){__r2.push((typeof __cmd2==='string'?__cmd2:('['+__cmd2.length+']'))+':dE');}}try{fG[wz(0x909)](__m,__mt,fG[wz(0xa77)]);}catch(e){}__L+=' || PBKEYSCAN='+__r2.join(',');}}catch(e){__L+=' || PBKEYSCANERR='+e.message;}if(window.__cmgDecLog===0x2){__L+=' || WASM2='+(window.__cmgCalls.slice(0,80).join(' ')||'NONE');}if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:__L});}}}catch(e){}return __out;})(jN[wz(0x944)])`;

export const cmgDecNew2 = `(function(__in){var __m=jJ[wz(0x97f)],__lvl=jJ[wz(0xb0b)]||{},__ts=__lvl[wz(0x291)],__k=fG[wz(0x22f)],__mt=(jJ[wz(0xb0b)]&&jJ[wz(0xb0b)]['mediaTagId'])!=null?jJ[wz(0xb0b)]['mediaTagId']:'NULL';var __out=fG[wz(0x6bf)](__m,__ts,__in,__k);try{
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
}catch(e){}try{if((jN['type']===0x5||jN['type']===0x1)){window.__cmgDecLog=(window.__cmgDecLog||0)+0x1;if(window.__cmgDecLog<=0x4B0){function __h(b,n){return b&&b.length>=n?Array.prototype.map.call(b.subarray(0x0,n),function(x){return('0'+x.toString(0x10)).slice(-0x2)}).join(''):'?';}function __eq(a,b){if(!a||!b||a.length!==b.length)return false;var __n=Math.min(a.length,0x100);for(var i=0;i<__n;i++)if(a[i]!==b[i])return false;return a.length===b.length;}function __kdesc(k){if(k==null)return 'null';if(typeof k==='string')return 'str('+k.length+')'+k.substring(0,40);if(k.length!==undefined)return (k.constructor&&k.constructor.name||'bytes')+'('+k.length+')'+__h(k,0x10);return typeof k;}function __fd(a,b){var r=[0,-1,-1];if(a&&b){var __mm=Math.min(a.length,b.length);for(var i=0;i<__mm;i++){if(a[i]!==b[i]){r[0]++;if(r[1]<0)r[1]=i;r[2]=i;}}}return r;}var __fdr=__fd(__out,__in);var __same=(__fdr[0]===0&&__out.length===__in.length)?'Y':'N';var __L='CMGDEC2#'+window.__cmgDecLog+' t='+jN['type']+' in='+__in.length+' out='+__out.length+' same='+__same+' diffN='+__fdr[0]+' first='+__fdr[1]+' last='+__fdr[2]+' inh='+__h(__in,0x10)+' outh='+__h(__out,0x10)+' ts='+__ts+' mt='+__mt+' key='+__kdesc(__k);if(window.__cmgDecLog===0x1){try{var __mod=__m||window.CNTVH5PlayerModule;__L+=' || MOD='+(__mod?Object.getOwnPropertyNames(__mod).join('|'):'NULL');if(__mod&&__mod.exports)__L+=' || EXP='+Object.getOwnPropertyNames(__mod.exports).join('|');__L+=' || A77='+__kdesc(fG[wz(0xa77)]);var __lv=jJ[wz(0xb0b)];__L+=' || LVL='+(__lv?Object.getOwnPropertyNames(__lv).join('|'):'NULL');}catch(e){__L+=' || DUMPERR='+e.message;}}if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:__L});}}}catch(e){}return __out;})(jN[wz(0x944)])`;

export const dispProbeOld = `jB[wk(0x909)]=function(jC,jD,jE){var wl=wk`;

export const dispProbeNew = `jB[wk(0x909)]=function(jC,jD,jE){try{if(window.chrome&&window.chrome.webview){var __jd=(typeof jD==='object'?(jD&&jD.length!==undefined?('['+jD.length+']'):(JSON.stringify(jD)||'').slice(0,120)):jD);var __loc=(self.location&&self.location.href)||'';0&&window.chrome.webview.postMessage({log:'[DISP] cmd='+jE+' jD='+__jd+' loc='+__loc.slice(0,90)});}}catch(e){}var wl=wk`;

export const initBlockOld = `self[jG(0x0,0x0,0x452,0x466)]=self[jG(0x0,0x0,0x450,0x46a)]||self[jG(0x0,0x0,0x43a,0x44a)][jG(0x0,0x0,0x463,0x471)]||window[jG(0x0,0x0,0x432,0x44a)][jG(0x0,0x0,0x461,0x471)]||window[jG(0x0,0x0,0x46e,0x46e)][jG(0x0,0x0,0x43a,0x44a)]||window[wl(0xb1d)][jG(0x0,0x0,0x454,0x454)]||'',jI[jG(0x0,0x0,0x46c,0x46d)](self[jG(0x0,0x0,0x44c,0x466)]['indexOf'](jG(0x0,0x0,0x45f,0x45d)),0x0)&&(self[jG(0x0,0x0,0x479,0x466)]=self['activeURL'][jG(0x0,0x0,0x46e,0x483)](jG(0x0,0x0,0x45f,0x45d),'')),self[jG(0x0,0x0,0x465,0x473)+jG(0x0,0x0,0x490,0x46b)]=!0x1,self[jG(0x0,0x0,0x461,0x44b)]='',jH=jC[jG(0x0,0x0,0x47b,0x461)+jG(0x0,0x0,0x459,0x44f)](jK)`;

export const initBlockNew = `(function(){var __post=function(t){try{if(window.chrome&&window.chrome.webview)0&&window.chrome.webview.postMessage({log:t});}catch(e){}};try{0&&__post('[DISP-INIT-ENTER] InitPlayer case entered');}catch(e){}var __head=jG(0x0,0x0,0x450,0x46a);try{0&&__post('[DISP-INIT] head='+__head+' headVal='+(self[__head])+' activeURL='+(self['activeURL'])+' location='+(self.location&&self.location.href));}catch(e){}try{self[jG(0x0,0x0,0x465,0x473)+jG(0x0,0x0,0x490,0x46b)]=!0x1;}catch(e){}try{self[jG(0x0,0x0,0x461,0x44b)]='';}catch(e){}var __mn=jG(0x0,0x0,0x47b,0x461)+jG(0x0,0x0,0x459,0x44f);var __has=!!(jC&&typeof jC[__mn]==='function');var __r;try{__r=jC[__mn](jK);}catch(__e){try{0&&__post('[DISP-INIT] m='+__mn+' has='+__has+' THREW='+__e.message);}catch(_x){}throw __e;}try{0&&__post('[DISP-INIT] m='+__mn+' has='+__has+' ret='+__r);}catch(_x){}jH=__r;})()`;

export const fetchGateOld = `if((!c||"EM_IDB_STORE"===r||"EM_IDB_DELETE"===r)&&!Fetch.dbInstance)return C(A),0;`;

export const fetchGateNew = `var __cmgRW=function(p){try{var u=UTF8ToString(p);if(/yangshipin\\\\.cn|cctv\\\\.cn/.test(u)&&u.indexOf('media?u=')<0){var nu='http://127.0.0.1:18888/media?u='+encodeURIComponent(u);var b=[];for(var i=0;i<nu.length;i++)b.push(nu.charCodeAt(i));b.push(0);var np=_malloc(b.length);if(np){for(var j=0;j<b.length;j++)HEAPU8[np+j]=b[j];HEAPU32[p>>2]=np;return nu;}}}catch(e){}return null;};try{if(window.chrome&&window.chrome.webview){var __gu=HEAPU32[A+8>>2]?UTF8ToString(HEAPU32[A+8>>2]):'?';0&&window.chrome.webview.postMessage({log:'[FETCH-GATE] db='+(Fetch.dbInstance?1:0)+' r='+r+' c='+c+' u='+__gu.substring(0,160)});}}catch(_e){}if("EM_IDB_STORE"!==r&&"EM_IDB_DELETE"!==r){try{var __rw=__cmgRW(HEAPU32[A+8>>2]);if(window.chrome&&window.chrome.webview)0&&window.chrome.webview.postMessage({log:'[FETCH-FORCE] '+(__rw||__gu)});}catch(_e){}__emscripten_fetch_xhr(A,o,C,E,Q);return A}if((!c||"EM_IDB_STORE"===r||"EM_IDB_DELETE"===r)&&!Fetch.dbInstance)return C(A),0;`;

export const FETCH_GATE_MARK = 'EM_IDB_STORE';

/**
 * ★ 注入版本号：参与本地 sapi 缓存文件名（inj_{ver}_{name}）。
 *   任何时候改动了上面的注入常量（earlyWrap / cmgDec* / dispProbe* / initBlock* / fetchGate*），
 *   **必须递增此值**，否则新版本 App 会继续复用旧的注入缓存，把错误版本固化下来。
 */
export const SAPI_INJECT_VER: string = 'v3';

/** sapi 脚本注入结果 */
export interface SapiInjectResult {
  text: string;    // 注入后的脚本文本
  ok: boolean;     // 关键锚点是否全部命中
  detail: string;  // 诊断串（各锚点命中情况）
}

/**
 * 对 /sapi 返回的 CMG 脚本执行注入。
 *
 * ★★ ok=false 的语义（非常重要）：
 *   源站脚本已变更、注入锚点失配 → 产物不可信。调用方必须：
 *     1. 不得把结果写入本地缓存（否则把错误版本固化，后续每次都错）；
 *     2. 运行期应回退到「网络直出」路径（与未注入等价，至少不会比坏注入更糟）。
 *   宁可慢 2.4s，也绝不能产出静默坏帧（绿屏/花屏）。
 */
export function injectSapiAsset(fileName: string, text: string, port: number): SapiInjectResult {
  // ① sapi 绝对 URL → 本地代理
  let out = text.split('https://sapi.yangshipin.cn').join('http://127.0.0.1:' + port + '/sapi');
  let ok = true;
  const details: string[] = [];

  // ② hls.cmg.js：解密调用点注入 + wasm 包装 + 派发器/InitPlayer 探针
  if (fileName.includes('hls.cmg.js')) {
    const hitDec: boolean = out.includes(cmgDecOld);
    const hitDec2: boolean = out.includes(cmgDecOld2);
    const hitDisp: boolean = out.includes(dispProbeOld);
    const hitInit: boolean = out.includes(initBlockOld);
    details.push(`decOld=${hitDec} decOld2=${hitDec2} disp=${hitDisp} init=${hitInit}`);
    // ★ 四个锚点缺一不可，缺任一即判失配（禁止缓存）
    ok = ok && hitDec && hitDec2 && hitDisp && hitInit;

    {
      let cmgNew = cmgDecNew;
      let cmgNew2 = cmgDecNew2;
      // 后处理（对齐 Go 842-854 行）
      cmgNew = cmgNew.split('window.__cmgDecLog<=0x28').join('window.__cmgDecLog<=0x4B0');
      cmgNew2 = cmgNew2.split('window.__cmgDecLog<=0x28').join('window.__cmgDecLog<=0x4B0');
      cmgNew = cmgNew.split("if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[WASM] '+__s});")
        .join("if(!/jsdecLive/i.test(n)&&(window.__cmgWCallCnt=(window.__cmgWCallCnt||{}),window.__cmgWCallCnt[n]=(window.__cmgWCallCnt[n]||0)+1)<=3&&window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[WASM] '+__s});");
      cmgNew2 = cmgNew2.split("if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[WASM] '+__s});")
        .join("if(!/jsdecLive/i.test(n)&&(window.__cmgWCallCnt=(window.__cmgWCallCnt||{}),window.__cmgWCallCnt[n]=(window.__cmgWCallCnt[n]||0)+1)<=3&&window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:'[WASM] '+__s});");
      cmgNew = cmgNew.split('window.__cmgDecLog=(window.__cmgDecLog||0)+0x1;')
        .join('window.__cmgDecLog=(window.__cmgDecLog||0)+0x1;try{var __hcD=function(a,b){var r=[0,-1,-1];if(a&&b){var m=Math.min(a.length,b.length);for(var i=0;i<m;i++){if(a[i]!==b[i]){r[0]++;if(r[1]<0)r[1]=i;r[2]=i;}}}return r;};var __hcDr=__hcD(__out,__in);var __hcS=(__hcDr[0]===0&&__out.length===__in.length)?\'Y\':\'N\';var __hcH=function(b,n){var s=\'\';try{for(var i=0;i<n&&i<b.length;i++)s+=(\'0\'+b[i].toString(16)).slice(-2);}catch(e){}return s;};if(__hcS===\'Y\'||window.__cmgDecLog%0xC8===0||window.__cmgDecLog<=0x3C){if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage({log:\'[CMG] #\'+window.__cmgDecLog+\' same=\'+__hcS+\' t=\'+jN.type+\' in=\'+__in.length+\' out=\'+__out.length+\' diffN=\'+__hcDr[0]+\' ts=\'+__ts+\' inh=\'+__hcH(__in,16)+\' outh=\'+__hcH(__out,16)});}}catch(e){}');
      // 诊断注入不能再调用解密器数百次或伪造 NALU：这些额外调用会污染 CMG 的有状态解密上下文，尤其容易破坏首个关键帧后的 P/B 帧。
      cmgNew = cmgNew.split('if(window.__cmgDecLog<=0x4B0){').join('if(false){');
      cmgNew2 = cmgNew2.split('if(window.__cmgDecLog<=0x4B0){').join('if(false){');
      cmgNew = cmgNew.split("} else if(jN['type']===0x5){").join("} else if(false&&jN['type']===0x5){");
      cmgNew2 = cmgNew2.split("} else if(jN['type']===0x5){").join("} else if(false&&jN['type']===0x5){");
      // 早装 wasm 包装器 prepend（★ 无条件前置，与改造前行为一致）
      //
      // ★★ 2026-08-30 修复：earlyWrap 以 `})()` 结尾，而源站 hls.cmg.js 以
      //    `(function(a,b){` 开头。直接 `earlyWrap + out` 会拼出：
      //        })()(function(a,b){ ... }(args));
      //    即把 earlyWrap 的返回值（undefined）当函数再调用一次。
      //    JS 先求值参数，所以 hls.cmg.js 的主 IIFE 仍会执行（播放不受影响），
      //    但随后立刻抛 `Uncaught TypeError: (intermediate value)... is not a function`，
      //    并导致该 IIFE 之后的脚本被中止 → 长期存在于日志中的噪音。
      //    补一个 `;\n` 分隔即可。
      out = earlyWrap + ';\n' + out;
      if (hitDec) {
        out = out.split(cmgDecOld).join(cmgNew);
      }
      if (hitDec2) {
        out = out.split(cmgDecOld2).join(cmgNew2);
      }
      if (hitDisp) {
        out = out.split(dispProbeOld).join(dispProbeNew);
      }
      if (hitInit) {
        out = out.split(initBlockOld).join(initBlockNew);
      }
    }
  }

  // ③ cmg.worker.js：绕过 IndexedDB → 强制 XHR（Fetch 门控）
  //    ★ 与改造前一致：对「任何含 FETCH_GATE_MARK 的响应」生效，不限定文件名
  if (out.includes(FETCH_GATE_MARK)) {
    const hitGate: boolean = out.includes(fetchGateOld);
    details.push(`fetchGate=${hitGate}`);
    ok = ok && hitGate;
    if (hitGate) {
      out = out.split(fetchGateOld).join(fetchGateNew);
    }
  }

  if (details.length === 0) {
    details.push('no-inject-required');
  }
  return { text: finishSapiInject(out, port), ok: ok, detail: details.join(' ') } as SapiInjectResult;
}

/** 注入收尾：日志静默 + 注入串内代理地址归一 */
function finishSapiInject(text: string, port: number): string {
  let t = text;
  // 日志静默（短路 postMessage）
  t = t.split('window.chrome.webview.postMessage').join('0&&window.chrome.webview.postMessage');
  t = t.split('post({log:').join('0&&post({log:');
  // 注入串内硬编码 127.0.0.1:18888 → 本机端口
  t = t.split('127.0.0.1:18888').join('127.0.0.1:' + port);
  return t;
}
