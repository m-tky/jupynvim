"""Generate examples/demo.ipynb with matplotlib output and an animated gif.

Run from anywhere:

    python examples/build_demo.py

Produces examples/demo.ipynb populated with rendered outputs so opening it in
jupynvim shows the demo immediately, without needing to execute any cells.

Dependencies: matplotlib, pillow, numpy.
"""

from __future__ import annotations

import base64
import io
import json
import os
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from PIL import Image, ImageDraw  # noqa: E402

OUT = Path(__file__).resolve().parent / "demo.ipynb"


def render_matplotlib_png() -> str:
    """Return a base64 PNG of a sample plot."""
    x = np.linspace(0, 4 * np.pi, 400)
    fig, ax = plt.subplots(figsize=(7, 3.5), dpi=110)
    ax.plot(x, np.sin(x), label="sin(x)", linewidth=2.0)
    ax.plot(x, np.cos(x), label="cos(x)", linewidth=2.0, linestyle="--")
    ax.fill_between(x, np.sin(x), 0, alpha=0.15)
    ax.set_title("Trigonometric demo", fontsize=12)
    ax.set_xlabel("x")
    ax.set_ylabel("amplitude")
    ax.legend(loc="upper right")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    buf = io.BytesIO()
    fig.savefig(buf, format="png")
    plt.close(fig)
    return base64.b64encode(buf.getvalue()).decode("ascii")


def make_gif() -> str:
    """Return a base64 animated gif."""
    size = 160
    frames: list[Image.Image] = []
    for k in range(24):
        im = Image.new("RGB", (size, size), (24, 24, 36))
        draw = ImageDraw.Draw(im)
        cx, cy = size // 2, size // 2
        radius = size // 3
        for i in range(8):
            angle = 2 * np.pi * (i / 8 + k / 24)
            x = cx + radius * np.cos(angle)
            y = cy + radius * np.sin(angle)
            shade = int(255 * (i + 1) / 8)
            draw.ellipse((x - 8, y - 8, x + 8, y + 8), fill=(shade, 100, 200))
        frames.append(im)
    buf = io.BytesIO()
    frames[0].save(
        buf,
        format="GIF",
        save_all=True,
        append_images=frames[1:],
        duration=80,
        loop=0,
        disposal=2,
    )
    return base64.b64encode(buf.getvalue()).decode("ascii")


def code_cell(source: str, outputs: list[dict] | None = None, exec_count: int | None = None) -> dict:
    return {
        "cell_type": "code",
        "metadata": {},
        "execution_count": exec_count,
        "source": source.splitlines(keepends=True),
        "outputs": outputs or [],
    }


def md_cell(source: str) -> dict:
    return {
        "cell_type": "markdown",
        "metadata": {},
        "source": source.splitlines(keepends=True),
    }


def stream_output(text: str) -> dict:
    return {"output_type": "stream", "name": "stdout", "text": text.splitlines(keepends=True)}


def display_png(png_b64: str) -> dict:
    return {
        "output_type": "display_data",
        "metadata": {},
        "data": {
            "image/png": png_b64,
            "text/plain": ["<Figure size 770x385 with 1 Axes>"],
        },
    }


def main() -> int:
    print("rendering matplotlib png...", flush=True)
    plot_png = render_matplotlib_png()
    print("rendering animated gif...", flush=True)
    gif_b64 = make_gif()

    nb = {
        "cells": [
            md_cell(
                "# jupynvim demo\n\n"
                "This notebook demonstrates what jupynvim renders inline:\n\n"
                "- **markdown cells** with headings, lists, bold/italic, and embedded images\n"
                "- **code cells** with Python source, stdout output, and matplotlib plots\n"
                "- **animated gifs** that loop natively in the terminal via the kitty\n"
                "  graphics protocol\n"
            ),
            md_cell(
                "## Animated gif\n\n"
                "Embedded right in the markdown source as a `data:image/gif;base64,...`\n"
                "URI. jupynvim extracts the frames with ImageMagick and re-transmits\n"
                "them on a timer so the gif animates at its native loop length.\n\n"
                f"![spinner](data:image/gif;base64,{gif_b64})\n"
            ),
            code_cell(
                "import numpy as np\n"
                "import matplotlib.pyplot as plt\n"
                "\n"
                "x = np.linspace(0, 4 * np.pi, 400)\n"
                "fig, ax = plt.subplots(figsize=(7, 3.5), dpi=110)\n"
                "ax.plot(x, np.sin(x), label='sin(x)', linewidth=2)\n"
                "ax.plot(x, np.cos(x), label='cos(x)', linewidth=2, linestyle='--')\n"
                "ax.fill_between(x, np.sin(x), 0, alpha=0.15)\n"
                "ax.set_title('Trigonometric demo')\n"
                "ax.legend()\n"
                "ax.grid(True, alpha=0.3)\n"
                "plt.show()\n",
                outputs=[display_png(plot_png)],
                exec_count=1,
            ),
            md_cell(
                "## Plain-text output\n\n"
                "Stream output renders directly inside the cell box. Long lines\n"
                "wrap with both side bars intact.\n"
            ),
            code_cell(
                "for i in range(5):\n"
                "    print(f'iteration {i}: {2 ** i}')\n",
                outputs=[
                    stream_output(
                        "iteration 0: 1\n"
                        "iteration 1: 2\n"
                        "iteration 2: 4\n"
                        "iteration 3: 8\n"
                        "iteration 4: 16\n"
                    )
                ],
                exec_count=2,
            ),
        ],
        "metadata": {
            "kernelspec": {
                "display_name": "Python 3",
                "language": "python",
                "name": "python3",
            },
            "language_info": {
                "name": "python",
                "version": "3.12",
                "mimetype": "text/x-python",
                "file_extension": ".py",
                "pygments_lexer": "ipython3",
            },
        },
        "nbformat": 4,
        "nbformat_minor": 5,
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(nb, indent=1) + "\n", encoding="utf-8")
    size_kb = OUT.stat().st_size // 1024
    print(f"wrote {OUT} ({size_kb} KB)", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
