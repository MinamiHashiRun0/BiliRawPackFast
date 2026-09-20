import yaml

p = r'E:\Documents\DSHWork\BiliRawPackFast\.github\workflows\build-probe.yml'
d = yaml.safe_load(open(p, encoding='utf-8').read())
print("jobs:")
for name, job in d['jobs'].items():
    ro = job.get('runs-on')
    steps = job.get('steps', [])
    print("  %-26s runs-on=%-14s steps=%d" % (name, ro, len(steps)))
    for s in steps:
        print("       - %s" % s.get('name'))
