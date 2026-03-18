#!/usr/bin/env python3

import sys
import os
import csv
import yaml
import math
import time
import subprocess

def help_message():
    print(f"Usage: {os.path.basename(sys.argv[0])} <YAML>")
    print("Please provide exactly one argument: the path to the YAML spec file.")

def main():
    if len(sys.argv) != 2:
        help_message()
        sys.exit(1)

    spec_file = sys.argv[1]
    base_dir = os.path.dirname(spec_file)
    if not base_dir:
        base_dir = "."

    print(f"Reading spec: {spec_file}")
    with open(spec_file, "r", encoding="utf-8") as f:
        spec = yaml.safe_load(f)

    input_spec = spec["input"]
    data_csv = os.path.join(base_dir, input_spec["data"])
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

    # 1) Remove intermediate directory if it exists
    intermediate_dir = os.path.join(output_dir, "intermediate")
    print(f"Removing any existing intermediate directory: {intermediate_dir}")
    subprocess.run(["rm", "-rf", intermediate_dir], check=True)

    # 2) Read CSV and create intermediate SVGs
    print(f"Reading data CSV: {data_csv}")
    os.makedirs(intermediate_dir, exist_ok=True)

    headers = []
    total = 0

    with open(data_csv, "r", encoding="utf-8") as csvfile:
        reader = csv.reader(csvfile)
        for row_index, row in enumerate(reader):
            if row_index == 0:
                # First row is column headers
                headers = row
                print(f"Replacing with headers: {headers}")
            else:
                sign_filename = f"sign_{row_index:04d}.svg"
                sign_path = os.path.join(intermediate_dir, sign_filename)

                # Replace placeholders in the template and write out an SVG
                with open(tmpl_svg, "r", encoding="utf-8") as tmpl_f, \
                     open(sign_path, "w", encoding="utf-8") as sign_f:
                    for line in tmpl_f:
                        for col_idx, col_val in enumerate(row):
                            col_val = col_val if col_val else ""
                            line = line.replace(headers[col_idx], col_val)
                        sign_f.write(line)

                # 3) Vectorize (text-to-path) the SVG via Inkscape
                #    Overwrite the original file in place
                #    (exactly as in the Ruby script)
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
