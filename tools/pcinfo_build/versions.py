# SPDX-License-Identifier: GPL-2.0-only
# Based on Alpine apk-tools src/version.c, v2.14.6.
# Copyright (C) 2005-2008 Natanael Copa
# Copyright (C) 2008-2011 Timo Teräs
# Python adaptation for PCInfo Classic, 2026.
# License: licenses/COPYING.GPL-2.0
"""apk-toolsと同じトークン順序でAlpineの版を比較する。"""
from __future__ import annotations

INVALID, ZERO, NUMBER, LETTER, SUFFIX, SUFFIX_NUMBER, REVISION, END = range(-1, 7)
PRE = ("alpha", "beta", "pre", "rc")
POST = ("cvs", "svn", "git", "hg", "p")


class Tokens:
    def __init__(self, version):
        self.remaining, self.kind = version, NUMBER

    def next(self):
        text = self.remaining
        if not text:
            self.kind = END
            return 0
        special = None
        if self.kind == ZERO and text[0] == "0":
            length = len(text) - len(text.lstrip("0")) - 1
            value, special = -length, NUMBER
        elif self.kind in (ZERO, NUMBER, SUFFIX_NUMBER, REVISION):
            length = 0
            while length < len(text) and text[length].isdigit():
                length += 1
            if length >= 18 or not length:
                raise ValueError(f"不正なAlpineバージョン: {text}")
            value = int(text[:length])
        elif self.kind == LETTER:
            length, value = 1, ord(text[0])
        elif self.kind == SUFFIX:
            suffix = next((s for s in PRE + POST if text.startswith(s)), None)
            if suffix is None:
                raise ValueError(f"不正なAlpine suffix: {text}")
            length = len(suffix)
            value = PRE.index(suffix) - len(PRE) if suffix in PRE else POST.index(suffix)
        else:
            raise ValueError(f"不正なAlpineバージョン: {text}")
        self.remaining = text[length:]
        if not self.remaining:
            self.kind = END
        elif special is not None:
            self.kind = special
        else:
            self.advance()
        return value

    def advance(self):
        text, previous = self.remaining, self.kind
        if previous in (NUMBER, ZERO) and "a" <= text[0] <= "z":
            target = LETTER
        elif previous == LETTER and text[0].isdigit():
            target = NUMBER
        elif previous == SUFFIX and text[0].isdigit():
            target = SUFFIX_NUMBER
        else:
            if text.startswith("-r"):
                target, self.remaining = REVISION, text[2:]
            elif text[0] in "._":
                target, self.remaining = {".": ZERO, "_": SUFFIX}[text[0]], text[1:]
            else:
                raise ValueError(f"不正なAlpineバージョン区切り: {text}")
        allowed = ((ZERO, NUMBER), (SUFFIX, SUFFIX_NUMBER), (NUMBER, LETTER))
        if target < previous and (target, previous) not in allowed:
            raise ValueError(f"不正なAlpineバージョン順序: {text}")
        self.kind = target


def compare(left: str, right: str) -> int:
    """左が古ければ-1、同じなら0、新しければ1。"""
    a, b = Tokens(left), Tokens(right)
    av = bv = 0
    while a.kind == b.kind and a.kind != END and av == bv:
        av, bv = a.next(), b.next()
    if av != bv:
        return (av > bv) - (av < bv)
    if a.kind == b.kind:
        return 0
    ak, bk = a.kind, b.kind
    if a.kind == SUFFIX and a.next() < 0:
        return -1
    if b.kind == SUFFIX and b.next() < 0:
        return 1
    return (bk > ak) - (bk < ak)
