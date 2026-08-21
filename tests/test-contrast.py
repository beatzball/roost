#!/usr/bin/env python3
"""Fail if any shipped theme violates the readability thresholds.
Metrics: WCAG contrast for text-on-bg (luminance); CIE76 ΔE for
'are these two chips distinguishable' (hue+luminance). ΔE >= 20 is
calibrated from the roost default the user accepted (logo/active = 23.4)."""
import math, subprocess, sys, os

def rgb(h): h=h.lstrip('#'); return tuple(int(h[i:i+2],16) for i in (0,2,4))
def _l(c):
    c/=255; return c/12.92 if c<=0.03928 else ((c+0.055)/1.055)**2.4
def lum(h): r,g,b=rgb(h); return 0.2126*_l(r)+0.7152*_l(g)+0.0722*_l(b)
def contrast(a,b):
    la,lb=lum(a),lum(b); hi,lo=max(la,lb),min(la,lb); return (hi+0.05)/(lo+0.05)
def _lab(h):
    r,g,b=[_l(c) for c in rgb(h)]
    X=(r*0.4124+g*0.3576+b*0.1805)/0.95047; Y=r*0.2126+g*0.7152+b*0.0722
    Z=(r*0.0193+g*0.1192+b*0.9505)/1.08883
    f=lambda t: t**(1/3) if t>0.008856 else 7.787*t+16/116
    return (116*f(Y)-16, 500*(f(X)-f(Y)), 200*(f(Y)-f(Z)))
def dE(a,b):
    (l1,a1,b1),(l2,a2,b2)=_lab(a),_lab(b)
    return math.sqrt((l1-l2)**2+(a1-a2)**2+(b1-b2)**2)

ROLES=["bar-bg","bar-fg","logo-bg","active-bg","active-fg","idle-fg"]

def load_themes():
    here=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    src=os.path.join(here,"scripts","roost-themes.sh")
    names=subprocess.check_output(["sh","-c",f'. "{src}"; roost_theme_names'],text=True).split()
    out={}
    for n in names:
        vals=subprocess.check_output(["sh","-c",f'. "{src}"; roost_theme {n}'],text=True).split()
        out[n]=dict(zip(ROLES,vals))
    return out

def check(name,t):
    fails=[]
    def C(a,b,m,lbl):
        r=contrast(t[a],t[b])
        if r<m: fails.append(f"{lbl}: {r:.2f} < {m}")
    C("bar-fg","bar-bg",4.5,"bar-fg on bar-bg")
    C("idle-fg","bar-bg",4.5,"idle-fg on bar-bg")
    C("active-fg","active-bg",4.5,"active-fg on active-bg")
    C("active-bg","bar-bg",3.0,"wedge active-bg on bar-bg")
    C("active-fg","logo-bg",3.0,"logo text on logo-bg (bold)")
    d=dE(t["logo-bg"],t["active-bg"])
    if d<20: fails.append(f"logo vs active ΔE: {d:.1f} < 20")
    return fails

if __name__=="__main__":
    themes=load_themes(); bad=0
    for n,t in themes.items():
        f=check(n,t)
        if f:
            bad+=1; print(f"FAIL {n}"); [print(f"    {x}") for x in f]
        else:
            print(f"PASS {n}")
    sys.exit(1 if bad else 0)
