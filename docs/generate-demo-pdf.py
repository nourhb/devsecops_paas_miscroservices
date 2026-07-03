#!/usr/bin/env python3
"""Generate DEVSECOPS_PAAS_DEMO_COMMANDS.pdf from the markdown source."""
from __future__ import annotations

import re
import sys
from pathlib import Path

from fpdf import FPDF
from fpdf.enums import XPos, YPos

DOCS = Path(__file__).resolve().parent
MD_FILE = DOCS / "DEVSECOPS_PAAS_DEMO_COMMANDS.md"
PDF_FILE = DOCS / "DEVSECOPS_PAAS_DEMO_COMMANDS.pdf"

FONT_CANDIDATES = [
    Path(r"C:\Windows\Fonts\arial.ttf"),
    Path(r"C:\Windows\Fonts\Arial.ttf"),
    Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
    Path("/usr/share/fonts/TTF/DejaVuSans.ttf"),
]


def pick_font() -> Path | None:
    for p in FONT_CANDIDATES:
        if p.is_file():
            return p
    return None


class DemoPDF(FPDF):
    def header(self) -> None:
        if self.page_no() == 1:
            return
        self.set_font("body", "", 8)
        self.set_text_color(120, 120, 120)
        self.cell(0, 8, "DevSecOps PaaS — Guide de démonstration", align="R")
        self.ln(4)

    def footer(self) -> None:
        self.set_y(-12)
        self.set_font("body", "", 8)
        self.set_text_color(120, 120, 120)
        self.cell(0, 8, f"Page {self.page_no()}", align="C")


def setup_fonts(pdf: DemoPDF) -> None:
    font_path = pick_font()
    if font_path:
        pdf.add_font("body", "", str(font_path))
        bold = font_path.parent / "arialbd.ttf"
        mono = font_path.parent / "cour.ttf"
        pdf.add_font("body", "B", str(bold if bold.is_file() else font_path))
        pdf.add_font("mono", "", str(mono if mono.is_file() else font_path))
    else:
        pdf.set_doc_option("core_fonts_encoding", "utf-8")
        for name in ("body", "mono"):
            pdf.add_font(name, "", "Helvetica")
            pdf.add_font(name, "B", "Helvetica")


def write_title(pdf: DemoPDF, text: str) -> None:
    pdf.set_font("body", "B", 18)
    pdf.set_text_color(20, 60, 120)
    pdf.multi_cell(0, 10, text)
    pdf.ln(2)


def write_h2(pdf: DemoPDF, text: str) -> None:
    pdf.ln(4)
    pdf.set_font("body", "B", 13)
    pdf.set_text_color(30, 90, 150)
    pdf.multi_cell(0, 8, text)
    pdf.ln(1)


def write_h3(pdf: DemoPDF, text: str) -> None:
    pdf.ln(2)
    pdf.set_font("body", "B", 11)
    pdf.set_text_color(50, 50, 50)
    pdf.multi_cell(0, 7, text)
    pdf.ln(1)


def write_para(pdf: DemoPDF, text: str) -> None:
    pdf.set_font("body", "", 10)
    pdf.set_text_color(30, 30, 30)
    text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    pdf.multi_cell(0, 5.5, text)
    pdf.ln(1)


def write_code_block(pdf: DemoPDF, lines: list[str]) -> None:
    pdf.set_fill_color(245, 247, 250)
    pdf.set_draw_color(200, 210, 220)
    pdf.set_font("mono", "", 8)
    pdf.set_text_color(20, 20, 20)
    w = pdf.w - pdf.l_margin - pdf.r_margin
    line_h = 4.2
    h = max(line_h * len(lines) + 4, line_h + 4)
    if pdf.get_y() + h > pdf.h - pdf.b_margin:
        pdf.add_page()
    y0 = pdf.get_y()
    pdf.rect(pdf.l_margin, y0, w, h, style="DF")
    pdf.set_xy(pdf.l_margin + 2, y0 + 2)
    for line in lines:
        pdf.cell(w - 4, line_h, line.replace("\t", "    "), new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.set_y(y0 + h + 2)


def write_table(pdf: DemoPDF, rows: list[list[str]]) -> None:
    if not rows:
        return
    col_count = max(len(r) for r in rows)
    w = pdf.w - pdf.l_margin - pdf.r_margin
    col_w = w / col_count
    for i, row in enumerate(rows):
        if pdf.get_y() > pdf.h - 20:
            pdf.add_page()
        pdf.set_fill_color(230, 240, 250 if i == 0 else 255)
        pdf.set_text_color(20, 20, 20)
        pdf.set_font("body", "B" if i == 0 else "", 9)
        for j in range(col_count):
            cell = row[j] if j < len(row) else ""
            cell = re.sub(r"\*\*(.+?)\*\*", r"\1", cell)
            pdf.cell(col_w, 7, cell[:60], border=1, fill=True)
        pdf.ln(7)
    pdf.ln(2)


def parse_markdown(md: str) -> None:
    pdf = DemoPDF()
    pdf.set_auto_page_break(auto=True, margin=15)
    setup_fonts(pdf)
    pdf.add_page()

    lines = md.splitlines()
    i = 0
    in_code = False
    code_buf: list[str] = []
    table_buf: list[list[str]] = []

    def flush_table() -> None:
        nonlocal table_buf
        if table_buf:
            data = [r for r in table_buf if not all(re.match(r"^[-:\s|]+$", c or "") for c in r)]
            write_table(pdf, data)
            table_buf = []

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        if in_code:
            if stripped.startswith("```"):
                write_code_block(pdf, code_buf)
                code_buf = []
                in_code = False
            else:
                code_buf.append(line)
            i += 1
            continue

        if stripped.startswith("```"):
            flush_table()
            in_code = True
            code_buf = []
            i += 1
            continue

        if stripped.startswith("|") and stripped.endswith("|"):
            cells = [c.strip() for c in stripped.strip("|").split("|")]
            table_buf.append(cells)
            i += 1
            continue
        flush_table()

        if stripped == "---":
            pdf.ln(2)
            i += 1
            continue

        if stripped.startswith("# "):
            write_title(pdf, stripped[2:].strip())
        elif stripped.startswith("## "):
            write_h2(pdf, stripped[3:].strip())
        elif stripped.startswith("### "):
            write_h3(pdf, stripped[4:].strip())
        elif stripped.startswith("- ") or stripped.startswith("* "):
            write_para(pdf, "  • " + stripped[2:])
        elif re.match(r"^\d+\.\s", stripped):
            write_para(pdf, "  " + stripped)
        elif stripped.startswith("*") and stripped.endswith("*") and len(stripped) > 2:
            pdf.set_font("body", "", 9)
            pdf.set_text_color(100, 100, 100)
            pdf.multi_cell(0, 5, stripped.strip("*"))
            pdf.ln(1)
        elif stripped:
            write_para(pdf, stripped)

        i += 1

    flush_table()
    pdf.output(str(PDF_FILE))


def main() -> int:
    if not MD_FILE.is_file():
        print(f"Missing source: {MD_FILE}", file=sys.stderr)
        return 1
    parse_markdown(MD_FILE.read_text(encoding="utf-8"))
    print(f"Created: {PDF_FILE}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
