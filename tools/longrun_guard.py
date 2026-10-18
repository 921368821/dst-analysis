#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""项目侧入口：转调用户级 skill `longrun-guard` 的实现。

为什么不在项目里复制一份实现：
  闸门必须**只有一个真相**。复制就会漂移，而漂移的判据比没有判据更危险
  （它会红得莫名其妙，然后被 --force 绕过，最后没人再看它）。

实现位置：~/.workbuddy/skills/longrun-guard/scripts/longrun_guard.py
用法：    python tools/longrun_guard.py <arm|beat|watch|gate|status|postmortem|selftest> ...
"""
import os
import runpy
import sys

REL = os.path.join(".workbuddy", "skills", "longrun-guard", "scripts", "longrun_guard.py")
CANDIDATES = [
    os.path.expanduser(REL),
    os.path.join(os.path.expanduser("~"), REL),
]


def main():
    for path in CANDIDATES:
        if os.path.exists(path):
            runpy.run_path(path, run_name="__main__")
            return 0
    sys.stderr.write(
        "找不到 longrun-guard 技能实现，试过：\n  " + "\n  ".join(CANDIDATES) + "\n"
        "请确认技能已安装到 ~/.workbuddy/skills/longrun-guard/。\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
