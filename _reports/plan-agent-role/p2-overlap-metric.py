import re,os,glob,itertools,sys
ANCH=re.compile(r'([A-Za-z0-9_./-]+\.(?:sh|md|py|lua|conf|json|service|toml|yml))[:#](\d+)')
FILE=re.compile(r'\b((?:bin|lib|test|nvim|docs|skills|systemd|harness\.d)/[A-Za-z0-9_./-]+)')
def sets(p,cap=None):
    t=open(p,errors='ignore').read()
    if cap: t=t[:cap]
    return ({f"{m.group(1)}:{m.group(2)}" for m in ANCH.finditer(t)},
            {m.group(1) for m in FILE.finditer(t)}, len(t))
def ov(a,b):
    return None if not a or not b else len(a&b)/min(len(a),len(b))
def row(d,cap):
    ex=sorted(glob.glob(os.path.join(d,'EXPLORE*.md')))
    if len(ex)<2: return None
    S=[sets(p,cap) for p in ex]
    fp=[ov(x[1],y[1]) for x,y in itertools.combinations(S,2)]
    ap=[ov(x[0],y[0]) for x,y in itertools.combinations(S,2)]
    fp=[v for v in fp if v is not None]; ap=[v for v in ap if v is not None]
    return (os.path.basename(d.rstrip('/')), os.path.exists(os.path.join(d,'RECON.md')),
            sum(x[2] for x in S)//len(S),
            sum(fp)/len(fp) if fp else None, sum(ap)/len(ap) if ap else None)
dirs=sys.argv[1:]
for cap,label in [(None,'FULL TEXT'),(4000,'FIRST 4000 CHARS (size-controlled)')]:
    print(f"\n### {label}")
    print(f"{'dispatch':26} {'RECON':>5} {'avg len':>8} {'file-overlap':>13} {'anchor-overlap':>15}")
    rs=[r for r in (row(d,cap) for d in dirs) if r]
    for n,rc,L,f,a in sorted(rs,key=lambda r:(not r[1],r[0])):
        fs='n/a' if f is None else f"{f:.2f}"; as_='n/a' if a is None else f"{a:.2f}"
        print(f"{n:26} {str(rc):>5} {L:>8} {fs:>13} {as_:>15}")
