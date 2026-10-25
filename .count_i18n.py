import io, re, sys

FENCE = chr(96) * 3


def stats(p):
    t = io.open(p, encoding='utf-8').read()
    lines = t.split('\n')
    heads = [l for l in lines if re.match(r'^#{1,6} ', l)]
    fences = [l for l in lines if l.strip().startswith(FENCE)]
    tables = [l for l in lines if l.startswith('|')]
    return heads, fences, tables


for p in sys.argv[1:]:
    heads, fences, tables = stats(p)
    print('==', p)
    print('headings', len(heads), 'fence-lines', len(fences), 'table-rows', len(tables))
    for l in heads:
        print('   ', l)
