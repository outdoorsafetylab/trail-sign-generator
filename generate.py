#!/usr/bin/env python3

import sys
import os
import argparse
import csv
import math
import re
import time
import subprocess

import yaml

def list_from(value):
    if value is None:
        return []
    if isinstance(value, list):
        return [item for item in value if item is not None]
    return [value]

def tag_named(tag, name):
    escaped = re.escape(name)
    return (
        re.search(rf'inkscape:label\s*=\s*["\']{escaped}["\']', tag) is not None
        or re.search(rf'\bid\s*=\s*["\']{escaped}["\']', tag) is not None
    )

def apply_display_none(tag):
    match = re.search(r'style\s*=\s*(["\'])(.*?)\1', tag, flags=re.DOTALL)
    if match:
        quote, style = match.group(1), match.group(2)
        if re.search(r'display\s*:', style):
            style = re.sub(r'display\s*:\s*[^;]*', 'display:none', style, count=1)
        else:
            style = f'display:none;{style}'
        return tag[:match.start()] + f'style={quote}{style}{quote}' + tag[match.end():]
    if tag.endswith('>'):
        return tag[:-1] + ' style="display:none">'
    return tag

def hide_svg_elements(svg, names):
    names = [str(name) for name in list_from(names) if str(name)]
    if not names:
        return svg
    def repl(match):
        tag = match.group(0)
        if any(tag_named(tag, name) for name in names):
            return apply_display_none(tag)
        return tag
    return re.sub(r'<[A-Za-z][\w:-]*\b[^>]*?>', repl, svg, flags=re.DOTALL)

def apply_fill_color(tag, color):
    color = str(color).strip()
    if not color:
        return tag
    match = re.search(r'style\s*=\s*(["\'])(.*?)\1', tag, flags=re.DOTALL)
    if match:
        quote, style = match.group(1), match.group(2)
        if re.search(r'fill\s*:', style):
            style = re.sub(r'fill\s*:\s*[^;]*', f'fill:{color}', style, count=1)
        else:
            style = f'fill:{color};{style}'
        return tag[:match.start()] + f'style={quote}{style}{quote}' + tag[match.end():]
    fill_attr = re.search(r'fill\s*=\s*(["\'])', tag)
    if fill_attr:
        quote = fill_attr.group(1)
        return re.sub(r'fill\s*=\s*(["\']).*?\1', f'fill={quote}{color}{quote}', tag, count=1)
    if tag.endswith('>'):
        return tag[:-1] + f' fill="{color}">'
    return tag

def recolor_svg_elements(svg, names, color):
    names = [str(name) for name in list_from(names) if str(name)]
    if not names or not str(color).strip():
        return svg
    def repl(match):
        tag = match.group(0)
        if any(tag_named(tag, name) for name in names):
            return apply_fill_color(tag, color)
        return tag
    return re.sub(r'<[A-Za-z][\w:-]*\b[^>]*?>', repl, svg, flags=re.DOTALL)

def line_kind(values):
    name = str(values.get('路線名稱') or '')
    if '支線' in name:
        return '支線'
    return '主線'

DEFAULT_FILL = {
    'background_color': {
        '主線': '#ffff00',
        '支線': '#f58635',
    }
}

def main():
    parser = argparse.ArgumentParser(
        add_help=True,
        usage="%(prog)s <YAML> [--hide-preview-layers]",
    )
    parser.add_argument("yaml", help="Path to the YAML spec file")
    parser.add_argument(
        "--hide-preview-layers",
        action="store_true",
        help="Hide layers listed in input.preview_layers (crop marks / hole previews)",
    )
    args = parser.parse_args()

    spec_file = args.yaml
    hide_preview_layers = args.hide_preview_layers
    base_dir = os.path.dirname(spec_file)
    if not base_dir:
        base_dir = "."

    print(f"Reading spec: {spec_file}")
    with open(spec_file, "r", encoding="utf-8") as f:
        spec = yaml.safe_load(f)

    input_spec = spec["input"]
    data_csvs = [
        os.path.join(base_dir, str(p)) for p in list_from(input_spec.get("data"))
    ]
    if not data_csvs:
        print(f"input.data is missing in {spec_file}", file=sys.stderr)
        sys.exit(1)
    tmpl_svg = os.path.join(base_dir, input_spec["template"])
    mask_svg = os.path.join(base_dir, input_spec["mask"])

    output_spec = spec["output"]
    output_dir = os.path.join(base_dir, output_spec["dir"])
    prefix = output_spec.get("prefix", "output_")

    slot_info = output_spec["slot"]
    gsubs = slot_info.get("gsub", {})  # dictionary of replacements
    repeat = slot_info["repeat"]
    max_num = repeat.get("num", None)
    slots_per_page = repeat["x"] * repeat["y"]
    hide_preview = list_from(input_spec.get("preview_layers"))
    hide_when_empty = input_spec.get("hide_when_empty") or {}
    if not isinstance(hide_when_empty, dict):
        hide_when_empty = {}
    if "fill" in input_spec:
        fill = input_spec.get("fill") or {}
    else:
        fill = DEFAULT_FILL
    if not isinstance(fill, dict):
        fill = {}
    if hide_preview_layers and not hide_preview:
        print(
            f"Warning: --hide-preview-layers was set, but input.preview_layers is empty in {spec_file}",
            file=sys.stderr,
        )
    if hide_preview_layers and hide_preview:
        print("Hiding preview layers: " + ", ".join(str(n) for n in hide_preview))

    # 1) Remove intermediate directory if it exists
    intermediate_dir = os.path.join(output_dir, "intermediate")
    print(f"Removing any existing intermediate directory: {intermediate_dir}")
    subprocess.run(["rm", "-rf", intermediate_dir], check=True)

    os.makedirs(intermediate_dir, exist_ok=True)

    headers = []
    total = 0
    reached_max = False
    with open(tmpl_svg, "r", encoding="utf-8") as tmpl_f:
        tmpl_text = tmpl_f.read()

    # utf-8-sig, not utf-8: CSVs exported from Excel carry a BOM, which would
    # otherwise stay glued to the first header name and stop that column's
    # placeholder from being substituted in the template.
    for data_csv in data_csvs:
        print(f"Reading data CSV: {data_csv}")
        with open(data_csv, "r", encoding="utf-8-sig") as csvfile:
            reader = csv.reader(csvfile)
            for row_index, row in enumerate(reader):
                if row_index == 0:
                    if not headers:
                        headers = row
                        print(f"Replacing with headers: {headers}")
                    elif row != headers:
                        print(
                            f"CSV header mismatch in {data_csv}: expected {headers}, got {row}",
                            file=sys.stderr,
                        )
                        sys.exit(1)
                else:
                    sign_filename = f"sign_{total + 1:04d}.svg"
                    sign_path = os.path.join(intermediate_dir, sign_filename)

                    svg = tmpl_text
                    values = {}
                    for col_idx, col_val in enumerate(row):
                        col_val = col_val if col_val else ""
                        header = headers[col_idx]
                        values[header] = col_val
                        svg = svg.replace(header, col_val)

                    if hide_preview_layers:
                        svg = hide_svg_elements(svg, hide_preview)
                    for header, names in hide_when_empty.items():
                        raw = values.get(str(header), "")
                        if not str(raw).strip():
                            svg = hide_svg_elements(svg, names)
                    kind = line_kind(values)
                    for element, colors in fill.items():
                        color = colors.get(kind) if isinstance(colors, dict) else colors
                        svg = recolor_svg_elements(svg, element, color)

                    with open(sign_path, "w", encoding="utf-8") as sign_f:
                        sign_f.write(svg)

                    print(f"Vectorizing SVG: {sign_path}")
                    subprocess.run([
                        "inkscape",
                        sign_path,
                        "--export-plain-svg",
                        "--export-text-to-path",
                        f"--export-filename={sign_path}"
                    ], check=True)

                    total += 1
                    if max_num is not None and total >= max_num:
                        reached_max = True
                        break
        if reached_max:
            break

    # 4) Determine how many pages we need
    num_pages = math.ceil(total / slots_per_page) if slots_per_page > 0 else 0

    # We'll keep track of the page PDFs in a list
    output_pdf_files = []

    # 5) Generate page_XX.svg, then convert them to PDF
    for page_num in range(1, num_pages + 1):
        page_svg = f"page_{page_num:02d}.svg"
        page_svg_path = os.path.join(intermediate_dir, page_svg)

        print(f"Creating page SVG: {page_svg_path}")
        with open(page_svg_path, "w", encoding="utf-8") as pf:
            w = output_spec["w"]
            h = output_spec["h"]
            pf.write(
                f'''<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<svg width="{w}mm" height="{h}mm" viewBox="0 0 {w} {h}" version="1.1"
     xmlns="http://www.w3.org/2000/svg"
     xmlns:svg="http://www.w3.org/2000/svg"
     xmlns:xlink="http://www.w3.org/1999/xlink">
'''
            )
            for slot_index in range(1, slots_per_page + 1):
                sign_num = slots_per_page * (page_num - 1) + slot_index
                if sign_num > total:
                    break

                # calculate the position
                slot_w = slot_info["w"]
                slot_h = slot_info["h"]
                x_count = (slot_index - 1) % repeat["x"]
                y_count = (slot_index - 1) // repeat["x"]
                x_pos = slot_info["x"] + x_count * slot_w
                y_pos = slot_info["y"] + y_count * slot_h

                # read the sign_Xxxx.svg
                sign_filename = f"sign_{sign_num:04d}.svg"
                sign_path = os.path.join(intermediate_dir, sign_filename)

                pf.write(f'<g transform="translate({x_pos},{y_pos})">\n')

                with open(sign_path, "r", encoding="utf-8") as sp:
                    for line_idx, line_content in enumerate(sp):
                        # skip the first line if it's the XML decl
                        if line_idx == 0 and line_content.strip().startswith('<?xml'):
                            continue
                        # Convert <svg to <g, etc.
                        line_content = line_content.replace("<svg", "<g")
                        line_content = line_content.replace("</svg>", "</g>")
                        # Apply gsubs
                        for k, v in gsubs.items():
                            line_content = line_content.replace(k, v)
                        pf.write(line_content)

                pf.write("</g>\n")

            pf.write("</svg>\n")

        # Export page_XX.svg to PDF with Inkscape
        page_pdf = f"page_{page_num:02d}.pdf"
        page_pdf_path = os.path.join(intermediate_dir, page_pdf)

        print(f"Exporting page PDF: {page_pdf_path}")
        subprocess.run([
            "inkscape",
            page_svg_path,
            "--export-plain-svg",
            "--export-text-to-path",
            f"--export-filename={page_pdf_path}"
        ], check=True)

        output_pdf_files.append(page_pdf_path)

    # 6) Create the mask SVG
    mask_svg_path = os.path.join(intermediate_dir, "mask.svg")
    print(f"Creating mask SVG: {mask_svg_path}")
    with open(mask_svg_path, "w", encoding="utf-8") as mf:
        w = output_spec["w"]
        h = output_spec["h"]
        mf.write(
            f'''<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<svg width="{w}mm" height="{h}mm" viewBox="0 0 {w} {h}" version="1.1"
     xmlns="http://www.w3.org/2000/svg"
     xmlns:svg="http://www.w3.org/2000/svg"
     xmlns:xlink="http://www.w3.org/1999/xlink">
'''
        )
        for slot_index in range(1, slots_per_page + 1):
            slot_w = slot_info["w"]
            slot_h = slot_info["h"]
            x_count = (slot_index - 1) % repeat["x"]
            y_count = (slot_index - 1) // repeat["x"]
            x_pos = slot_info["x"] + x_count * slot_w
            y_pos = slot_info["y"] + y_count * slot_h

            mf.write(f'<g transform="translate({x_pos},{y_pos})">\n')
            with open(mask_svg, "r", encoding="utf-8") as mk:
                for line_idx, line_content in enumerate(mk):
                    if line_idx == 0 and line_content.strip().startswith('<?xml'):
                        continue
                    line_content = line_content.replace("<svg", "<g")
                    line_content = line_content.replace("</svg>", "</g>")
                    for k, v in gsubs.items():
                        line_content = line_content.replace(k, v)
                    mf.write(line_content)
            mf.write("</g>\n")

        mf.write("</svg>\n")

    # 7) Export mask.svg to mask.pdf
    mask_pdf_path = os.path.join(intermediate_dir, "mask.pdf")
    print(f"Exporting mask PDF: {mask_pdf_path}")
    subprocess.run([
        "inkscape",
        mask_svg_path,
        "--export-plain-svg",
        "--export-text-to-path",
        f"--export-filename={mask_pdf_path}"
    ], check=True)

    # 8) Zip all SVG files
    timestamp = time.strftime('%Y%m%d%H%M%S')
    zip_file = f"{prefix}{timestamp}.zip"
    zip_cmd = f"zip ../{zip_file} *.svg"

    print(f"Creating zip for all SVG files: {zip_file}")
    # use shell command to change dir to intermediate, zip all .svg
    subprocess.run(zip_cmd, shell=True, cwd=intermediate_dir, check=True)
    # subprocess.run(zip_cmd, cwd=intermediate_dir, check=True)

    # 9) Merge PDFs with pdfunite
    merged_pdf_file = os.path.join(output_dir, f"{prefix}{timestamp}_RGB.pdf")
    print(f"Merging all PDF files: {merged_pdf_file}")
    # pdfunite <page1> <page2> ... <mask> <out>
    pdfunite_cmd = ["pdfunite"] + output_pdf_files + [mask_pdf_path, merged_pdf_file]
    subprocess.run(pdfunite_cmd, check=True)

    # 10) Convert to CMYK with Ghostscript
    merged_cmyk_pdf_file = os.path.join(output_dir, f"{prefix}{timestamp}_CMYK.pdf")
    print(f"Converting to CMYK: {merged_cmyk_pdf_file}")
    gs_cmd = [
        "gs",
        "-dSAFER",
        "-dBATCH",
        "-dNOPAUSE",
        "-dNOCACHE",
        "-sDEVICE=pdfwrite",
        "-dAutoRotatePages=/None",
        "-sColorConversionStrategy=CMYK",
        "-dProcessColorModel=/DeviceCMYK",
        f"-sOutputFile={merged_cmyk_pdf_file}",
        merged_pdf_file
    ]
    subprocess.run(gs_cmd, check=True)

    print("All done.")

if __name__ == "__main__":
    main()
