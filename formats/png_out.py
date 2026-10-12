# SPDX-License-Identifier: GPL-3.0-or-later
"""PNGOUT: selected objects to a PNG on a transparent background.

Same drawing path as the plot (``pdf_out.build_graphics_scene``: the
canvas's own frontend, plot-style tables, Plot-off layers skipped), limited
to the selection. The image is cropped to what was selected, with a small
margin, and nothing is painted behind it: every pixel the drawing does not
touch keeps alpha 0. Colours are the plotted ones (ACI 7 black), the way
AutoCAD's output is meant to go onto a page, not the screen's dark canvas.
"""
from __future__ import annotations

from pathlib import Path

#: Long side of the image, in pixels, when the caller gives no size.
DEFAULT_LONG_SIDE = 2048
_MARGIN_RATIO = 0.02
_MAX_SIDE = 16384


class NothingToExport(Exception):
    """The selection drew nothing (hidden layer, Plot off, empty set)."""


def export_png(document, handles, path, layout_name: str | None = None,
               long_side: int = DEFAULT_LONG_SIDE, ctb: str | None = None):
    """Write the entities named by ``handles`` to ``path``; return (w, h)."""
    from PySide6.QtCore import QRectF, Qt
    from PySide6.QtGui import QColor, QImage, QPainter

    from formats import pdf_out

    handles = {str(h) for h in handles}
    if not handles:
        raise NothingToExport("no objects selected")
    scene = pdf_out.build_graphics_scene(document, layout_name, ctb,
                                         handles=handles)
    rect = pdf_out.scene_extents(scene)
    if scene.items() == [] or (rect.width() <= 0 and rect.height() <= 0):
        raise NothingToExport("the selection draws nothing")
    long_side = max(16, min(int(long_side), _MAX_SIDE))
    pad = max(rect.width(), rect.height()) * _MARGIN_RATIO
    if pad <= 0:                       # a single point
        pad = 1.0
    rect = rect.adjusted(-pad, -pad, pad, pad)
    # a horizontal or vertical line has no area: give it the image's ratio
    scale = long_side / max(rect.width(), rect.height())
    width = max(1, round(rect.width() * scale))
    height = max(1, round(rect.height() * scale))

    scene.setBackgroundBrush(Qt.NoBrush)   # the backend paints the sheet white
    image = QImage(width, height, QImage.Format_ARGB32)
    image.fill(QColor(0, 0, 0, 0))
    painter = QPainter(image)
    try:
        painter.setRenderHints(QPainter.Antialiasing | QPainter.TextAntialiasing
                               | QPainter.SmoothPixmapTransform)
        # DXF is y-up, the image y-down
        painter.translate(0.0, height)
        painter.scale(1.0, -1.0)
        scene.render(painter, QRectF(0, 0, width, height), rect,
                     Qt.IgnoreAspectRatio)
    finally:
        painter.end()
    path = Path(path)
    if not image.save(str(path), "PNG"):
        raise OSError(f"cannot write {path}")
    return width, height
