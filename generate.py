#!/usr/bin/env python3
import argparse
import csv
import math
import shutil
import subprocess
import time
import zipfile
import logging
from pathlib import Path
import yaml

try:
    from PyPDF2 import PdfMerger
except ImportError:
    PdfMerger = None

logging.basicConfig(level=logging.INFO, format='%(message)s')

def run_cmd(cmd, cwd=None):
    logging.info(f"Running command: {cmd}")
    subprocess.run(cmd, shell=True, check=True, cwd=cwd)

def vectorize_svg(svg_file: Path):
    """Run Inkscape to vectorize the SVG."""
    cmd = f'inkscape "{svg_file}" --export-plain-svg --export-text-to-path --export-filename="{svg_file}"'
    run_cmd(cmd)

def merge_pdfs(pdf_files, output_pdf):
    """Merge PDF files using PyPDF2 if available, else fallback to pdfunite."""
    if PdfMerger:
        merger = PdfMerger()
        for pdf in pdf_files:
            merger.append(str(pdf))
        with output_pdf.open("wb") as fout:
            merger.write(fout)
        merger.close()
    else:
        pdf_files_str = " ".join(f'"{p}"' for p in pdf_files)
        cmd = f'pdfunite {pdf_files_str} "{output_pdf}"'
        run_cmd(cmd)

def convert_to_cmyk(input_pdf: Path, output_pdf: Path):
    """Convert a PDF to CMYK using Ghostscript."""
    cmd = (
        f'gs -dSAFER -dBATCH -dNOPAUSE -dNOCACHE -sDEVICE=pdfwrite '
        f'-dAutoRotatePages=/None -sColorConversionStrategy=CMYK '
        f'-dProcessColorModel=/DeviceCMYK -sOutputFile="{output_pdf}" "{input_pdf}"'
    )
    run_cmd(cmd)

def process_csv_and_create_svgs(spec, base_dir: Path, intermediate_dir: Path) -> int:
    """Process the CSV, generate intermediate SVG files, and vectorize them."""
    input_spec = spec['input']
    data_file = base_dir / input_spec['data']
    template_file = base_dir / input_spec['template']
    
    total = 0
    cols = []

    logging.info(f"Reading CSV data: {data_file}")
    with data_file.open(newline='', encoding="utf-8-sig") as csvfile:
        reader = csv.reader(csvfile)
        for row_num, row in enumerate(reader):
            if row_num == 0:
                cols = row
                logging.info(f"Using headers: {cols}")
            else:
                svg_filename = intermediate_dir / f"sign_{row_num:04d}.svg"
                logging.info(f"Creating intermediate SVG: {svg_filename}")
                with svg_filename.open("w", encoding="utf-8") as outfile:
                    with template_file.open("r", encoding="utf-8") as tmpl:
                        for line in tmpl:
                            for col_num, value in enumerate(row):
                                # Use an empty string if value is None or empty.
                                value = value or ""
                                header = cols[col_num]
                                line = line.replace(header, value)
                            outfile.write(line)
                vectorize_svg(svg_filename)
                total += 1
                max_num = spec['output']['slot']['repeat'].get('num')
                if max_num is not None and total >= max_num:
                    break
    return total

def create_page_svgs(spec, intermediate_dir: Path, total: int) -> (list, list):
    """Compose intermediate SVGs into page layouts and convert them to PDFs."""
    output_spec = spec['output']
    slot = output_spec['slot']
    repeat = slot['repeat']
    slots_per_page = repeat['x'] * repeat['y']
    num_pages = math.ceil(total / slots_per_page)
    
    output_svg_files = []
    output_pdf_files = []
    page_w = output_spec['w']
    page_h = output_spec['h']
    
    for i in range(1, num_pages + 1):
        page_svg = intermediate_dir / f"page_{i:02d}.svg"
        logging.info(f"Creating page SVG: {page_svg}")
        with page_svg.open("w", encoding="utf-8") as f:
            f.write('<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n')
            f.write(f'<svg width="{page_w}mm" height="{page_h}mm" viewBox="0 0 {page_w} {page_h}" '
                    'version="1.1" xmlns="http://www.w3.org/2000/svg" '
                    'xmlns:svg="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">\n')
            
            for j in range(1, slots_per_page + 1):
                slot_w = slot['w']
                slot_h = slot['h']
                x = ((j - 1) % repeat['x']) * slot_w + slot['x']
                y = ((j - 1) // repeat['x']) * slot_h + slot['y']
                n = slots_per_page * (i - 1) + j
                if n > total:
                    break
                sign_svg = intermediate_dir / f"sign_{n:04d}.svg"
                f.write(f'<g transform="translate({x},{y})">\n')
                with sign_svg.open("r", encoding="utf-8") as infile:
                    for line_num, line in enumerate(infile):
                        if line_num == 0:
                            continue  # skip XML declaration
                        line = line.replace('<svg', '<g').replace('</svg>', '</g>')
                        for k, v in slot.get('gsub', {}).items():
                            line = line.replace(k, v)
                        f.write(line)
                f.write('</g>\n')
            f.write('</svg>\n')
        output_svg_files.append(page_svg)
        
        page_pdf = intermediate_dir / f"page_{i:02d}.pdf"
        logging.info(f"Exporting page PDF: {page_pdf}")
        cmd = f'inkscape "{page_svg}" --export-plain-svg --export-text-to-path --export-filename="{page_pdf}"'
        run_cmd(cmd)
        output_pdf_files.append(page_pdf)
    
    return output_svg_files, output_pdf_files

def create_mask_svg(spec, intermediate_dir: Path, base_dir: Path) -> Path:
    """Create a mask SVG file based on the provided mask template and export it to PDF."""
    output_spec = spec['output']
    slot = output_spec['slot']
    repeat = slot['repeat']
    slots_per_page = repeat['x'] * repeat['y']
    page_w = output_spec['w']
    page_h = output_spec['h']
    
    input_spec = spec['input']
    mask_file = Path(input_spec['mask'])
    if not mask_file.is_absolute():
        mask_file = base_dir / mask_file

    mask_svg = intermediate_dir / "mask.svg"
    logging.info(f"Creating mask SVG: {mask_svg}")
    with mask_svg.open("w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n')
        f.write(f'<svg width="{page_w}mm" height="{page_h}mm" viewBox="0 0 {page_w} {page_h}" '
                'version="1.1" xmlns="http://www.w3.org/2000/svg" '
                'xmlns:svg="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">\n')
        for j in range(1, slots_per_page + 1):
            slot_w = slot['w']
            slot_h = slot['h']
            x = ((j - 1) % repeat['x']) * slot_w + slot['x']
            y = ((j - 1) // repeat['x']) * slot_h + slot['y']
            f.write(f'<g transform="translate({x},{y})">\n')
            with mask_file.open("r", encoding="utf-8") as infile:
                for line_num, line in enumerate(infile):
                    if line_num == 0:
                        continue
                    line = line.replace('<svg', '<g').replace('</svg>', '</g>')
                    for k, v in slot.get('gsub', {}).items():
                        line = line.replace(k, v)
                    f.write(line)
            f.write('</g>\n')
        f.write('</svg>\n')
    mask_pdf = intermediate_dir / "mask.pdf"
    logging.info(f"Exporting mask PDF: {mask_pdf}")
    cmd = f'inkscape "{mask_svg}" --export-plain-svg --export-text-to-path --export-filename="{mask_pdf}"'
    run_cmd(cmd)
    return mask_pdf

def zip_svgs(intermediate_dir: Path, output_zip: Path):
    """Zip all SVG files from the intermediate directory."""
    logging.info(f"Creating zip for SVG files: {output_zip}")
    with zipfile.ZipFile(output_zip, 'w', zipfile.ZIP_DEFLATED) as zipf:
        for svg_file in intermediate_dir.glob("*.svg"):
            zipf.write(svg_file, arcname=svg_file.name)

def main():
    parser = argparse.ArgumentParser(description="Process a YAML spec to generate SVGs and PDFs.")
    parser.add_argument("yaml_file", help="Path to the YAML spec file")
    args = parser.parse_args()
    
    base_dir = Path(args.yaml_file).resolve().parent
    spec_path = Path(args.yaml_file)
    logging.info(f"Reading spec: {spec_path}")
    with spec_path.open("r", encoding="utf-8") as f:
        spec = yaml.safe_load(f)
    
    output_spec = spec['output']
    output_dir = base_dir / output_spec['dir']
    intermediate_dir = output_dir / "intermediate"
    if intermediate_dir.exists():
        shutil.rmtree(intermediate_dir)
    intermediate_dir.mkdir(parents=True, exist_ok=True)
    
    total = process_csv_and_create_svgs(spec, base_dir, intermediate_dir)
    _, output_pdf_files = create_page_svgs(spec, intermediate_dir, total)
    mask_pdf = create_mask_svg(spec, intermediate_dir, base_dir)
    
    timestamp = time.strftime('%Y%m%d%H%M%S')
    svg_zip = output_dir / f"{output_spec['prefix']}{timestamp}.zip"
    zip_svgs(intermediate_dir, svg_zip)
    
    merged_rgb = output_dir / f"{output_spec['prefix']}{timestamp}_RGB.pdf"
    pdf_files = output_pdf_files + [mask_pdf]
    logging.info(f"Merging PDFs into: {merged_rgb}")
    merge_pdfs(pdf_files, merged_rgb)
    
    merged_cmyk = output_dir / f"{output_spec['prefix']}{timestamp}_CMYK.pdf"
    logging.info(f"Converting merged PDF to CMYK: {merged_cmyk}")
    convert_to_cmyk(merged_rgb, merged_cmyk)
    
    logging.info("Processing completed successfully.")

if __name__ == "__main__":
    main()
