#!/usr/bin/env python3
"""Bracket-balance check for Dart source, string- and comment-aware.

WHY THIS EXISTS: there is no Flutter SDK on the NUC (#311), so `dart analyze`
cannot run here. This is the only static check available on this box before a
patch goes to the laptop to be compiled.

WHAT IT IS NOT: a compiler, a linter, or evidence that the code is correct. It
proves exactly one thing — that (), [] and {} are balanced outside of strings
and comments. Balanced code can still be nonsense. Never report a green run
here as "it compiles"; it does not know.

Handles: // and /* */ comments, single/double/triple-quoted strings, escapes,
and ${...} interpolation, which nests real Dart inside a string literal.

Usage:  tools/dart_balance_check.py lib/**/*.dart
Exit 0 if every file balances, 1 otherwise.
"""
import sys
def check(path):
    s=open(path).read()
    i=0; n=len(s); stack=[]; line=1
    pairs={'(' :')','[':']','{':'}'}
    while i<n:
        c=s[i]
        if c=='\n': line+=1; i+=1; continue
        if c=='/' and i+1<n and s[i+1]=='/':
            while i<n and s[i]!='\n': i+=1
            continue
        if c=='/' and i+1<n and s[i+1]=='*':
            i+=2
            while i+1<n and not (s[i]=='*' and s[i+1]=='/'):
                if s[i]=='\n': line+=1
                i+=1
            i+=2; continue
        if c in ('"',"'"):
            # triple quote?
            trip = s[i:i+3] in ('"""',"'''")
            q = s[i:i+3] if trip else c
            i += len(q)
            while i<n:
                if s[i]=='\\': i+=2; continue
                if s[i]=='\n': line+=1
                if s[i:i+len(q)]==q: i+=len(q); break
                # string interpolation ${...} can nest real code
                if s[i]=='$' and i+1<n and s[i+1]=='{':
                    depth=0; i+=1
                    while i<n:
                        if s[i]=='{': depth+=1
                        elif s[i]=='}':
                            depth-=1
                            if depth==0: i+=1; break
                        elif s[i]=='\n': line+=1
                        i+=1
                    continue
                i+=1
            continue
        if c in pairs: stack.append((c,line)); i+=1; continue
        if c in ')]}':
            if not stack:
                print(f"{path}:{line}: unmatched closing {c}"); return False
            o,ol=stack.pop()
            if pairs[o]!=c:
                print(f"{path}:{line}: {c} closes {o} opened line {ol}"); return False
            i+=1; continue
        i+=1
    if stack:
        o,ol=stack[-1]
        print(f"{path}: unclosed {o} from line {ol}"); return False
    print(f"{path}: balanced")
    return True
ok=all([check(p) for p in sys.argv[1:]])
sys.exit(0 if ok else 1)
