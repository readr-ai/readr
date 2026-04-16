"""Export dead_zones + hotspots as video-editor timeline markers.

Supports:
  - FCPXML (Final Cut Pro; also imported by DaVinci Resolve, Premiere via
    conversion, and several other NLEs). Markers placed at span starts
    with a length spanning the dead zone / hotspot.
  - CSV (a neutral format: in/out timecodes + colour + comment; any NLE
    that can import a marker CSV can read it).

The export endpoints accept a previously-scored result id and read its
persisted JSON payload — no need for the original media to be on the
server.
"""
from __future__ import annotations

import csv
import io
from typing import Iterable


def _tc(seconds: float, fps: int = 30) -> str:
    """HH:MM:SS:FF timecode at integer fps."""
    total_frames = int(round(seconds * fps))
    hh = total_frames // (fps * 3600)
    mm = (total_frames // (fps * 60)) % 60
    ss = (total_frames // fps) % 60
    ff = total_frames % fps
    return f"{hh:02d}:{mm:02d}:{ss:02d}:{ff:02d}"


def csv_markers(dead_zones: list, hotspots: list, fps: int = 30) -> str:
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["start_tc", "end_tc", "start_s", "end_s", "type", "color", "comment"])
    for s, e in dead_zones:
        w.writerow([_tc(s, fps), _tc(e, fps), f"{s:.2f}", f"{e:.2f}", "dead_zone", "red", "Low brain engagement -- consider cutting"])
    for s, e in hotspots:
        w.writerow([_tc(s, fps), _tc(e, fps), f"{s:.2f}", f"{e:.2f}", "hotspot", "green", "Peak engagement -- front-load"])
    return buf.getvalue()


def fcpxml(
    dead_zones: list,
    hotspots: list,
    duration_s: float,
    fps: int = 30,
    title: str = "CBT virality markers",
) -> str:
    """Minimal FCPXML 1.10 with a placeholder gap asset + markers."""
    rate = f"{fps * 1000}/1000s"  # e.g. 30000/1000s; rational seconds for Final Cut

    def frame_dur(t: float) -> str:
        frames = max(1, int(round(t * fps)))
        return f"{frames * (1000 // fps) if fps and (1000 % fps == 0) else frames}/{fps}s"

    def marker(s: float, e: float, kind: str, tint: str) -> str:
        start = f"{int(round(s * fps))}/{fps}s"
        dur = f"{max(1, int(round((e - s) * fps)))}/{fps}s"
        return (
            f'            <marker start="{start}" duration="{dur}" '
            f'value="{kind}" note="{tint}"/>\n'
        )

    markers = "".join(marker(s, e, "dead_zone", "red") for s, e in dead_zones) + \
              "".join(marker(s, e, "hotspot", "green") for s, e in hotspots)

    total_dur = f"{int(round(max(duration_s, 1.0) * fps))}/{fps}s"

    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>
<fcpxml version="1.10">
  <resources>
    <format id="r1" name="FFVideoFormat{1080}p{fps}" frameDuration="1/{fps}s" width="1080" height="1920"/>
  </resources>
  <library>
    <event name="CBT">
      <project name="{title}">
        <sequence format="r1" duration="{total_dur}" tcStart="0s" tcFormat="NDF">
          <spine>
            <gap name="placeholder" offset="0s" duration="{total_dur}" start="0s">
{markers}            </gap>
          </spine>
        </sequence>
      </project>
    </event>
  </library>
</fcpxml>
"""
