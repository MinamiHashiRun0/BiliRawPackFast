import yaml, sys

p = r'E:\Documents\DSHWork\BiliRawPackFast\.github\workflows\build-probe.yml'
d = yaml.safe_load(open(p, encoding='utf-8').read())
print('YAML 解析: OK')
print('顶层键:', list(d.keys()))
print('name    =', d.get('name'))
on = d.get(True, d.get('on'))
print('on keys =', list(on.keys()))
print('jobs    =', list(d['jobs'].keys()))
steps = d['jobs']['build']['steps']
print('步骤数  =', len(steps))
for i, s in enumerate(steps, 1):
    name = s.get('name')
    print('  %2d. %s' % (i, name))

problems = []
for s in steps:
    if 'run' in s and not s['run'].strip():
        problems.append('空 run 块: %s' % s.get('name'))
    if 'uses' in s and 'with' in s and not s['with']:
        problems.append('空 with: %s' % s.get('name'))
    # secrets 不得出现在 if:
    if 'if' in s and 'secrets.' in str(s['if']):
        problems.append('if 中引用了 secrets（工作流校验会失败）: %s' % s.get('name'))
    # 必须显式声明 if-no-files-found，避免静默空 artifact
    if str(s.get('uses', '')).startswith('actions/upload-artifact'):
        if s.get('with', {}).get('if-no-files-found') != 'error':
            problems.append('upload-artifact 未设 if-no-files-found=error: %s' % s.get('name'))

# heredoc 平衡检查：每个 <<'X' 都要有对应的独立 X 行
import re
for s in steps:
    body = s.get('run', '')
    for m in re.finditer(r"<<'([A-Za-z_]+)'", body):
        tag = m.group(1)
        if not re.search(r'^%s$' % re.escape(tag), body, re.M):
            problems.append('heredoc %s 没有结束标记: %s' % (tag, s.get('name')))

print()
if problems:
    print('发现问题:')
    for x in problems:
        print('  !!', x)
    sys.exit(1)
print('校验通过 ✅')
