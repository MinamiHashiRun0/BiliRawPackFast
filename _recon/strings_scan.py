"""
从脱壳后的 bili-universal 主二进制里抽取字符串与 ObjC/Swift 符号线索。
目的：定位
  ① 网络栈用法（NSURLSession vs 自研）
  ② 证书固定（pinning）迹象
  ③ playurl / CDN URL 解析点
  ④ AVPlayer / 资源加载器用法
  ⑤ 反调试 / 越狱 / 完整性自检迹象
"""
import zipfile, struct, re, os, json, collections

IPA = r"E:\Documents\DSHWork\BiliRawPackFast\哔哩哔哩-弹幕番剧直播高清视频_9.12.0.ipa"
EXE_IN_ZIP = "Payload/bili-universal.app/bili-universal"
OUT = r"E:\Documents\DSHWork\BiliRawPackFast\_recon"
os.makedirs(OUT, exist_ok=True)

z = zipfile.ZipFile(IPA)
with z.open(EXE_IN_ZIP) as f:
    blob = f.read()
print(f"主二进制大小: {len(blob):,} 字节")

# --- 解析段表，只取 __TEXT 与 __DATA_CONST 的字符串区 ---
LC_SEGMENT_64 = 0x19
cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, res = struct.unpack("<iiIIIII", blob[4:32])
segs = {}
off = 32
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack("<II", blob[off:off + 8])
    if cmd == LC_SEGMENT_64:
        segname = blob[off + 8:off + 24].rstrip(b"\x00").decode("latin1")
        vmaddr, vmsize, fileoff, filesize = struct.unpack("<QQQQ", blob[off + 24:off + 56])
        segs[segname] = (fileoff, filesize)
    off += cmdsize
print("段:", {k: f"{v[0]:,}+{v[1]:,}" for k, v in segs.items()})

# --- 抽取 ASCII 字符串（长度>=5）---
ascii_re = re.compile(rb"[\x20-\x7e]{5,}")
def strings_from(segname):
    fo, fs = segs[segname]
    return [m.group().decode("latin1") for m in ascii_re.finditer(blob[fo:fo + fs])]

text_str = strings_from("__TEXT")
data_str = strings_from("__DATA_CONST") + strings_from("__DATA")
allstr = text_str + data_str
print(f"字符串总数: {len(allstr):,}  (__TEXT {len(text_str):,} / __DATA* {len(data_str):,})")

uniq = sorted(set(allstr))
print(f"去重后: {len(uniq):,}")

with open(os.path.join(OUT, "strings_all.txt"), "w", encoding="utf-8", errors="replace") as f:
    f.write("\n".join(uniq))

# --- 分组检索 ---
GROUPS = {
    "网络栈-NSURLSession": [r"NSURLSession", r"URLSession", r"dataTask", r"downloadTask", r"uploadTask",
                            r"URLSessionConfiguration", r"ephemeralSession", r"backgroundSession"],
    "网络栈-其它": [r"CFNetwork", r"nw_connection", r"NSURLConnection", r"CFReadStream", r"NWConnection",
                    r"Network\.framework", r"HTTPURLResponse", r"URLRequest"],
    "证书固定-pinning": [r"SecTrust", r"serverTrust", r"pinned", r"Pinned", r"pinCertificate",
                         r"publicKeyPin", r"AFSecurityPolicy", r"allowsInvalidSSLCertificate",
                         r"SSLPinning", r"CertificatePinning", r"evaluateServerTrust",
                         r"kSecTrustSettings", r"SSLVerify", r"challenge.*disposition"],
    "AVPlayer-播放": [r"AVPlayer", r"AVPlayerItem", r"AVAssetResourceLoader", r"AVURLAsset",
                      r"resourceLoader", r"AVAssetResourceLoadingRequest", r"AVPlayerLayer",
                      r"AVAudioSession", r"AVPlayerItemVideoOutput"],
    "playurl/CDN": [r"playurl", r"playUrl", r"PlayUrl", r"bilivideo", r"upgcxcode", r"hdnts",
                    r"backup_url", r"backupUrl", r"base_url", r"baseUrl", r"upsig", r"deadline",
                    r"cdn", r"CDN", r"Cdn", r"mirror", r"hosts"],
    "反调试/越狱/完整性": [r"ptrace", r"PT_DENY_ATTACH", r"sysctl", r"sysctlbyname", r"jailbr",
                           r"Jailbr", r"cydia", r"Cydia", r"/bin/bash", r"substrate", r"Substrate",
                           r"frida", r"Frida", r"gum", r"__RESTRICT", r"getenv", r"dyld_",
                           r"codeSign", r"csops", r"CS_OPS", r"tamper", r"integrity", r"signature"],
    "代码注入面": [r"insert_dylib", r"DYLD_INSERT", r"LC_LOAD", r"dlopen", r"dlsym", r"objc_getClass",
                   r"class_getInstanceMethod", r"method_exchangeImplementations", r"swizzl",
                   r"hook", r"Hook", r"fishhook"],
    "Lynx(自研UI引擎)": [r"[Ll]ynx", r"LynxView", r"LynxTemplate"],
    "HTTP代理-系统": [r"CFNetworkCopyProxiesForURL", r"connectionProxyDictionary", r"HTTPProxy",
                      r"proxyHost", r"proxyPort", r"NSURLSessionProxy"],
}

hits = {}
for gname, pats in GROUPS.items():
    rx = re.compile("|".join(f"(?:{p})" for p in pats))
    found = [s for s in uniq if rx.search(s)]
    hits[gname] = found
    print(f"\n=== {gname}  ({len(found)} 条) ===")
    for s in found[:60]:
        print("   ", s[:150])
    if len(found) > 60:
        print(f"    ... 另有 {len(found)-60} 条")

with open(os.path.join(OUT, "keyword_groups.json"), "w", encoding="utf-8") as f:
    json.dump(hits, f, ensure_ascii=False, indent=2)

# --- Swift demangle 线索：直接抓 _T 前缀符号不多，改抓 swift 模块名 ---
swift_mods = collections.Counter()
for s in uniq:
    for m in re.finditer(r"\b(\d{1,3})([A-Za-z_][A-Za-z0-9_]{2,30})(?=V|C|O|P|f|M|0)", s):
        swift_mods[m.group(2)] += 1
print("\n=== Swift 模块名高频候选（粗筛）===")
for name, cnt in swift_mods.most_common(40):
    print(f"   {name:<35} {cnt}")

print("\n输出:", OUT)
