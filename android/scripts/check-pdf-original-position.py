#!/usr/bin/env python3
"""Manual real-model regression. Open readr-pdf-test-book (the two-page
KokoroAudioTest export) in the app with Kokoro installed before running.
Checks Listen -> end of PDF -> original pages -> return, without touching
any other book. Requires adb on PATH and the API 35 test emulator.
"""
import pathlib
import re
import subprocess
import time
import xml.etree.ElementTree as ET


def adb(*args):
    return subprocess.check_output(["adb", *args])


def state():
    adb("shell", "uiautomator", "dump", "/sdcard/readr-position-qa.xml")
    return ET.fromstring(adb("shell", "cat", "/sdcard/readr-position-qa.xml"))


def tap(node):
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds")))
    adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))


def find(root, key, value):
    return next((n for n in root.iter("node") if n.get(key) == value), None)


root = state()
if not any(n.get("text", "").startswith("PDF page") for n in root.iter("node")):
    fixture = find(root, "text", "readr-pdf-test-book")
    assert fixture is not None, "Import the generated PDF fixture first"
    tap(fixture)
    root = state()
assert any(n.get("text", "").startswith("readr-pdf-test-bo") for n in root.iter("node")), "Open only the generated PDF test book"
assert any("of 2" in n.get("text", "") and n.get("text", "").startswith("PDF page") for n in root.iter("node")), "Expected the two-page PDF fixture"
listen = find(root, "content-desc", "Listen")
if listen is not None:
    tap(listen)
else:
    play = find(root, "content-desc", "Play")
    if play is not None:
        tap(play)
deadline = time.monotonic() + 90
while time.monotonic() < deadline:
    root = state()
    final_page = any(n.get("text", "").startswith("PDF page 2 of 2") for n in root.iter("node"))
    if final_page and find(root, "content-desc", "Play") is not None:
        break
    time.sleep(.2)
else:
    raise AssertionError("Real PDF narration did not finish")
tap(find(root, "text", "PDF"))
root = state()
assert find(root, "text", "Original PDF") is not None
# Let asynchronous bitmap sizing settle, as in a real reading visit.
time.sleep(2)
root = state()
tap(find(root, "content-desc", "Back to reading text"))
root = state()
labels = [n.get("text") for n in root.iter("node") if n.get("text", "").startswith("PDF page")]
assert any(s.startswith("PDF page 2 of 2") for s in labels), f"Original view reset the reading position: {labels}"
print("PASS: real PDF narration finished and original-page visit preserved page 2")
