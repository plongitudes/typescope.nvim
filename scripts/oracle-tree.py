#!/usr/bin/env python3
"""Print a typescope/structure JSON answer as a compact tree. Dev aid:
    oracle/target/debug/typescope-oracle --probe FILE LINE COL | scripts/oracle-tree.py
"""
import json, sys
d = json.load(sys.stdin)
if d is None:
    print("null"); sys.exit()
print(f"scope={d['scope']}" + (f"  header={d['header']}" if d.get('header') else ""))
def show(n, ind):
    flags = []
    if n.get('inferred'): flags.append('≈')
    if n.get('expandable'): flags.append('▸')
    if n.get('origin'): flags.append('↑' + n['origin'])
    if n.get('badge'): flags.append(n['badge'])
    if n.get('pass_mode'): flags.append(n['pass_mode'])
    d = f" = {n['default']}" if n.get('default') else ""
    loc = f"  @{n['location']['line']+1}:{n['location']['character']}" if n.get('location') else ""
    print(f"{ind}{n['kind']:<11} {n['name']:<16} {n['type']['display'][:60]:<60} [{n['type']['category']}]{d}  {' '.join(flags)}{loc}")
    for c in n.get('children', []): show(c, ind + "  ")
for r in d['roots']: show(r, "")
