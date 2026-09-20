"""把 HAR 里 upos / akamai 类视频请求的 URL 原貌打出来（token 做截断）。"""
import json, re, os, collections

HAR = r"E:\Documents\DSHWork\BiliRawPackFast\2026-09-18-064450.har"
with open(HAR, "r", encoding="utf-8", errors="replace") as f:
    har = json.load(f)
entries = har["log"]["entries"]

def host_of(u):
    m = re.match(r'https?://([^/]+)', u)
    return m.group(1) if m else "?"

# 所有 host 含 bilivideo / akamaized / hdslb 且非 api 的请求
cands = []
for e in entries:
    u = e["request"]["url"]
    h = host_of(u)
    if "bilivideo" in h or "akamaized" in h or "mcdn" in h:
        cands.append(e)

print(f"视频类 host 请求：{len(cands)} 条\n")
for i, e in enumerate(cands):
    u = e["request"]["url"]
    h = host_of(u)
    rest = re.sub(r'^https?://[^/]+', '', u)
    path, _, query = rest.partition("?")
    print("=" * 70)
    print(f"[{i+1}] {h}")
    print(f"     method={e['request']['method']}  status={e['response'].get('status')}  "
          f"size={e['response'].get('content',{}).get('size','?')}  "
          f"ip={e['request'].get('serverIPAddress','?')}")
    print(f"     path  : {path}")
    hs = {x["name"].lower(): x["value"] for x in e["request"].get("headers", [])}
    if "range" in hs:
        print(f"     Range : {hs['range']}")
    # 查询参数逐个列出（长值截断）
    params = re.findall(r'([^&=]+)=([^&]*)', query)
    print(f"     参数（{len(params)}）:")
    for k, v in params:
        if len(v) > 48:
            print(f"        {k:<14} = <{len(v)}> {v[:16]}…{v[-8:]}")
        else:
            print(f"        {k:<14} = {v}")
