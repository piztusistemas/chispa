# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Marco Sumari Tellez and IngeCAD contributors.
"""PNGOUT: the selected objects as a PNG on a transparent background."""
from __future__ import annotations

import pytest
from PySide6.QtGui import QImage

from formats import png_out




def _window(qapp):
    from core import actions
    from views.main_window import MainWindow

    win = MainWindow()
    win.show()
    win.new_document()
    win.tools._execute(actions.add_line((0, 0), (100, 0)))
    win.tools._execute(actions.add_line((0, 500), (100, 500)))
    qapp.processEvents()
    return win


def test_only_the_selected_objects_are_drawn_on_transparency(qapp, tmp_path):
    win = _window(qapp)
    try:
        lines = list(win.document.doc.modelspace().query("LINE"))
        keep = [l for l in lines if l.dxf.start.y == 0]
        out = tmp_path / "out.png"
        w, h = png_out.export_png(win.document, [e.dxf.handle for e in keep],
                                  out, "Model", long_side=400)
        image = QImage(str(out))
        assert (image.width(), image.height()) == (w, h)
        assert max(w, h) == 400
        assert image.hasAlphaChannel()
        alphas = [image.pixelColor(x, y).alpha()
                  for x in range(0, w, 3) for y in range(0, h, 3)]
        assert min(alphas) == 0, "background is not transparent"
        assert max(alphas) > 0, "nothing was drawn"
        # the other line (500 units away) would have made the image tall
        assert w > h * 3
    finally:
        win.document.dirty = False
        win.close()


def test_empty_selection_writes_nothing(qapp, tmp_path):
    win = _window(qapp)
    try:
        with pytest.raises(png_out.NothingToExport):
            png_out.export_png(win.document, [], tmp_path / "x.png")
        assert not (tmp_path / "x.png").exists()
    finally:
        win.document.dirty = False
        win.close()


def test_pngout_command_uses_the_preselection(qapp, tmp_path, monkeypatch):
    win = _window(qapp)
    try:
        out = tmp_path / "sel"
        monkeypatch.setattr(type(win.tools), "ask_save_file",
                            lambda self, *a: str(out))
        line = next(iter(win.document.doc.modelspace().query("LINE")))
        win.tools.selection = {line.dxf.handle}
        said = []
        win.command_line.echo = lambda text, *a, **k: said.append(text)
        win._on_command_submitted("PNGOUT")
        qapp.processEvents()
        assert out.with_suffix(".png").is_file(), said
        assert any("exported" in s for s in said), said
        assert win.tools.tool is None
    finally:
        win.document.dirty = False
        win.close()
