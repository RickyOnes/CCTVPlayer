using System;
using System.IO;
using System.Text;
using Wasmtime;

namespace CCTVPlayer;

public class YspState
{
    public string Version { get; set; } = "v1";
    public string Guid { get; set; } = string.Empty;
    public string Yspappid { get; set; } = "519748109";
    public string Host { get; set; } = "yangshipin.cn";
    public string Protocol { get; set; } = "https:";
    public string Token { get; set; } = string.Empty;
    public string Input { get; set; } = string.Empty;
    public string Ts { get; set; } = string.Empty;
    public string Pid { get; set; } = string.Empty;
}

public class WasmSigner : IDisposable
{
    private readonly Engine _engine;
    private readonly Module _module;
    private readonly Store _store;
    private readonly Linker _linker;
    private Instance? _instance;
    private Memory? _memory;
    private YspState _state;
    private readonly Dictionary<int, string> _handles = new();
    private int _nextHandle = 1;
    private Function? _malloc, _getTokenRnd, _getSignature;

    public WasmSigner()
    {
        _engine = new Engine();
        _module = Module.FromFile(_engine, Path.Combine(AppContext.BaseDirectory, "keygen_bg.wasm"));
        _store = new Store(_engine);
        _linker = new Linker(_engine);
        _state = new YspState();
        _linker.Define("wbg", "__wbg_get_9c1840f7ecd81363",
            Function.FromCallback<int, int, int>(_store, (p, l) => {
                var path = ReadStr(p, l);
                var val = Resolve(path);
                int h = _nextHandle++; _handles[h] = val; return h;
            }));
        _linker.Define("wbg", "__wbindgen_string_get",
            Function.FromCallback(_store, (Action<int, int>)((d, h) => {
                var b = Encoding.UTF8.GetBytes(_handles[h]);
                int p = (int)_malloc!.Invoke(b.Length, 1)!; var m = _memory!;
                m.WriteInt32(d, p); m.WriteInt32(d + 4, b.Length);
                for (int i = 0; i < b.Length; i++) m.WriteByte(p + i, b[i]);
            })));
        _linker.Define("wbg", "__wbindgen_object_drop_ref",
            Function.FromCallback(_store, (Action<int>)(h => _handles.Remove(h))));
    }

    public void SetState(YspState s, bool fresh = true)
    {
        _state = s;
        if (fresh || _instance == null) {
            _instance = _linker.Instantiate(_store, _module); _memory = _instance.GetMemory("memory")!;
            _malloc = _instance.GetFunction("__wbindgen_malloc")!;
            _getTokenRnd = _instance.GetFunction("get_token_rnd")!;
            _getSignature = _instance.GetFunction("get_signature")!;
        }
    }

    string Resolve(string p) => p switch {
        "cctvh5openapi.state.version" => _state.Version,
        "cctvh5openapi.state.guid" => _state.Guid,
        "cctvh5openapi.state.yspappid" => _state.Yspappid,
        "window.location.host" => _state.Host,
        "window.location.protocol" => _state.Protocol,
        "cctvh5openapi.state.token" => _state.Token,
        "cctvh5openapi.state.input" => _state.Input,
        "cctvh5openapi.state.ts" => _state.Ts,
        "cctvh5openapi.state.query.pid" => _state.Pid, _ => string.Empty
    };

    string ReadStr(int p, int l) { var m = _memory!; var b = new byte[l]; for (int i = 0; i < l; i++) b[i] = m.ReadByte(p + i); return Encoding.UTF8.GetString(b); }
    public string GetTokenRnd() { int r = (int)_malloc!.Invoke(8, 4)!; _getTokenRnd!.Invoke(r); var m = _memory!; return ReadStr(m.ReadInt32(r), m.ReadInt32(r + 4)); }
    public string GetSignature() { int r = (int)_malloc!.Invoke(8, 4)!; _getSignature!.Invoke(r); var m = _memory!; return ReadStr(m.ReadInt32(r), m.ReadInt32(r + 4)); }
    public void Dispose() { _linker?.Dispose(); _store?.Dispose(); _module?.Dispose(); _engine?.Dispose(); }
}