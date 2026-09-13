require 'csv'
require 'fileutils'
require 'rake'
require 'yaml'
require 'base64'

def help
  puts "#{__FILE__} <YAML> [--hide-preview-layers]"
end

def list_from(value)
  case value
  when nil then []
  when Array then value.compact
  else [value]
  end
end

def tag_named?(tag, name)
  escaped = Regexp.escape(name)
  tag.match?(/inkscape:label\s*=\s*["']#{escaped}["']/) ||
    tag.match?(/\bid\s*=\s*["']#{escaped}["']/)
end

def apply_display_none(tag)
  if tag =~ /style\s*=\s*(['"])(.*?)\1/m
    quote = $1
    style = $2
    style = if style =~ /display\s*:/
              style.sub(/display\s*:\s*[^;]*/, 'display:none')
            else
              "display:none;#{style}"
            end
    tag.sub(/style\s*=\s*(['"]).*?\1/m, "style=#{quote}#{style}#{quote}")
  else
    tag.sub(/>\z/, ' style="display:none">')
  end
end

def hide_svg_elements(svg, names)
  names = list_from(names).map(&:to_s).reject(&:empty?)
  return svg if names.empty?

  svg.gsub(/<[A-Za-z][\w:-]*\b[^>]*?>/m) do |tag|
    if names.any? { |name| tag_named?(tag, name) }
      apply_display_none(tag)
    else
      tag
    end
  end
end

def apply_fill_color(tag, color)
  color = color.to_s.strip
  return tag if color.empty?

  if tag =~ /style\s*=\s*(['"])(.*?)\1/m
    quote = $1
    style = $2
    style = if style =~ /fill\s*:/
              style.sub(/fill\s*:\s*[^;]*/, "fill:#{color}")
            else
              "fill:#{color};#{style}"
            end
    tag.sub(/style\s*=\s*(['"]).*?\1/m, "style=#{quote}#{style}#{quote}")
  elsif tag =~ /fill\s*=\s*(['"])/
    quote = $1
    tag.sub(/fill\s*=\s*(['"]).*?\1/, "fill=#{quote}#{color}#{quote}")
  else
    tag.sub(/>\z/, " fill=\"#{color}\">")
  end
end

def recolor_svg_elements(svg, names, color)
  names = list_from(names).map(&:to_s).reject(&:empty?)
  return svg if names.empty? || color.to_s.strip.empty?

  svg.gsub(/<[A-Za-z][\w:-]*\b[^>]*?>/m) do |tag|
    if names.any? { |name| tag_named?(tag, name) }
      apply_fill_color(tag, color)
    else
      tag
    end
  end
end

def line_kind(values)
  name = values['路線名稱'].to_s
  return '支線' if name.include?('支線')
  '主線'
end

def inkscape_export(src, dest = src)
  sh "inkscape --batch-process #{src} --export-plain-svg --export-text-to-path --export-filename=#{dest}"
end

DEFAULT_FILL = {
  'background_color' => {
    '主線' => '#ffff00',
    '支線' => '#f58635',
  }
}.freeze

if ARGV.empty?
  help
  exit 1
end

args = ARGV.dup
hide_preview_layers = !args.delete('--hide-preview-layers').nil?
unknown_flags = args.select { |a| a.start_with?('-') }
unless unknown_flags.empty?
  warn "Unknown option(s): #{unknown_flags.join(' ')}"
  help
  exit 1
end
if args.size != 1
  help
  exit 1
end

puts "Reading spec: #{args[0]}"
spec_file = args[0]
base_dir = File.dirname(spec_file)
spec = YAML.load_file(spec_file)
input = spec['input']
data_files = list_from(input['data']).map { |p| File.join(base_dir, p.to_s) }
if data_files.empty?
  warn "input.data is missing in #{spec_file}"
  exit 1
end
tmpl = File.join(base_dir, input['template'])
mask = File.join(base_dir, input['mask'])
output = spec['output']
output_dir = File.join(base_dir, output['dir'])
slot = output['slot']
gsubs = slot['gsub']
gsubs = {} unless gsubs
repeat = slot['repeat']
max = repeat['num']
slots_per_pages = repeat['x']*repeat['y']
preview_layers = list_from(input['preview_layers'])
hide_when_empty = input['hide_when_empty'] || {}
hide_when_empty = {} unless hide_when_empty.is_a?(Hash)
fill = input.key?('fill') ? (input['fill'] || {}) : DEFAULT_FILL
fill = {} unless fill.is_a?(Hash)

if hide_preview_layers && preview_layers.empty?
  warn "Warning: --hide-preview-layers was set, but input.preview_layers is empty in #{spec_file}"
end
if hide_preview_layers && !preview_layers.empty?
  puts "Hiding preview layers: #{preview_layers.join(', ')}"
end

cols = []
total = 0
last_kind = '主線'
tmpl_text = File.read(tmpl)

sh "rm -rf #{output_dir}/intermediate/"

data_files.each do |data|
  puts "Reading data CSV: #{data}"
  CSV.foreach(data, encoding: 'bom|utf-8').with_index do |row, row_num|
    if row_num == 0
      if cols.empty?
        row.each { |col| cols.push(col) }
        puts "Replacing with headers: #{cols}"
      elsif row != cols
        warn "CSV header mismatch in #{data}: expected #{cols.inspect}, got #{row.inspect}"
        exit 1
      end
    else
      filename = sprintf("sign_%04d.svg", total + 1)
      FileUtils.mkdir_p("#{output_dir}/intermediate/")
      intermediate = "#{output_dir}/intermediate/#{filename}"
      puts "Creating intermediate SVG: #{intermediate}"
      svg = tmpl_text.dup
      values = {}
      row.each_with_index do |col, col_num|
        col = "" unless col
        header = cols[col_num]
        values[header] = col
        svg = svg.gsub(header, col) if header
      end
      svg = hide_svg_elements(svg, preview_layers) if hide_preview_layers
      hide_when_empty.each do |header, names|
        raw = values[header.to_s]
        if raw.nil? || raw.to_s.strip.empty?
          svg = hide_svg_elements(svg, names)
        end
      end
      kind = line_kind(values)
      last_kind = kind
      fill.each do |element, colors|
        color = colors.is_a?(Hash) ? colors[kind] : colors
        svg = recolor_svg_elements(svg, element, color)
      end
      File.write(intermediate, svg)
      puts "Vectorizing SVG: #{intermediate}"
      inkscape_export(intermediate)
      total += 1
      break if max && total >= max
    end
  end
  break if max && total >= max
end

remain = if slots_per_pages.positive? && total.positive?
           (slots_per_pages - (total % slots_per_pages)) % slots_per_pages
         else
           0
         end
blank_tmpl_name = input['blank_template']
if blank_tmpl_name && remain.positive?
  puts "Padding #{remain} blank sign(s) to fill the last page"
  blank_text = File.read(File.join(base_dir, blank_tmpl_name.to_s))
  blank_headers = []
  blank_rows = []
  if input['blank_data']
    CSV.foreach(File.join(base_dir, input['blank_data'].to_s), encoding: 'bom|utf-8').with_index do |row, row_num|
      if row_num.zero?
        blank_headers = row
      else
        blank_rows << row
      end
    end
  end
  remain.times do |i|
    filename = sprintf("sign_%04d.svg", total + 1)
    FileUtils.mkdir_p("#{output_dir}/intermediate/")
    intermediate = "#{output_dir}/intermediate/#{filename}"
    svg = blank_text.dup
    values = { '路線名稱' => last_kind }
    unless blank_rows.empty?
      brow = blank_rows[i % blank_rows.length]
      brow.each_with_index do |col, col_num|
        col = '' unless col
        header = blank_headers[col_num]
        values[header] = col
        svg = svg.gsub(header, col) if header
      end
    end
    svg = hide_svg_elements(svg, preview_layers) if hide_preview_layers
    kind = line_kind(values)
    fill.each do |element, colors|
      color = colors.is_a?(Hash) ? colors[kind] : colors
      svg = recolor_svg_elements(svg, element, color)
    end
    File.write(intermediate, svg)
    puts "Vectorizing SVG: #{intermediate}"
    inkscape_export(intermediate)
    total += 1
  end
end

num_pages = (total.to_f / slots_per_pages).ceil()
output_svg_files = []
output_pdf_files = []

for i in 1..num_pages do
  output_svg_file = "#{output_dir}/intermediate/#{sprintf("page_%02d.svg", i)}"
  puts "Creating page SVG: #{output_svg_file}"
  File.open(output_svg_file, "w+") do |f|
    f.puts '<?xml version="1.0" encoding="UTF-8" standalone="no"?>'
    w = output['w']
    h = output['h']
    f.puts "<svg width=\"#{w}mm\" height=\"#{h}mm\" viewBox=\"0 0 #{w} #{h}\" version=\"1.1\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:svg=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\">"
    for j in 1..slots_per_pages do
      w = slot['w']
      h = slot['h']
      x = ((j-1) % repeat['x'])
      y = ((j-1) / repeat['x']).floor()
      x *= w
      y *= h
      x += slot['x']
      y += slot['y']
      n = slots_per_pages*(i-1)+j
      input_file = "#{output_dir}/intermediate/#{sprintf("sign_%04d.svg", n)}"
      # base64 = Base64.encode64(File.read(input_file))
      # f.puts "<image x=\"#{x}\" y=\"#{y}\" width=\"#{w}\" height=\"#{h}\" xlink:href=\"data:image/svg+xml;base64,#{base64}\" />"
      f.puts "<g transform=\"translate(#{x},#{y})\">"
      File.foreach(input_file).with_index do |line, line_num|
        next if line_num == 0
        line = line.gsub('<svg', '<g').gsub('</svg>', '</g>')
        gsubs.each do |k,v|
          line = line.gsub(k, v)
        end
        f.puts line
      end
      f.puts '</g>'
      break if n >= total
    end
    f.puts '</svg>'
  end
  output_svg_files.push output_svg_file
  output_pdf_file = "#{output_dir}/intermediate/#{sprintf("page_%02d.pdf", i)}"
  puts "Exporting page PDF: #{output_pdf_file}"
  inkscape_export(output_svg_file, output_pdf_file)
  output_pdf_files.push output_pdf_file
end

mask_svg_file = "#{output_dir}/intermediate/mask.svg"
puts "Creating mask SVG: #{mask_svg_file}"
File.open(mask_svg_file, "w+") do |f|
  f.puts '<?xml version="1.0" encoding="UTF-8" standalone="no"?>'
  w = output['w']
  h = output['h']
  f.puts "<svg width=\"#{w}mm\" height=\"#{h}mm\" viewBox=\"0 0 #{w} #{h}\" version=\"1.1\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:svg=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\">"
  for j in 1..slots_per_pages do
    w = slot['w']
    h = slot['h']
    x = ((j-1) % repeat['x'])
    y = ((j-1) / repeat['x']).floor()
    x *= w
    y *= h
    x += slot['x']
    y += slot['y']
    # base64 = Base64.encode64(File.read(mask))
    # f.puts "<image x=\"#{x}\" y=\"#{y}\" width=\"#{w}\" height=\"#{h}\" xlink:href=\"data:image/svg+xml;base64,#{base64}\" />"
    f.puts "<g transform=\"translate(#{x},#{y})\">"
    File.foreach(mask).with_index do |line, line_num|
      next if line_num == 0
      line = line.gsub('<svg', '<g').gsub('</svg>', '</g>')
      gsubs.each do |k,v|
        line = line.gsub(k, v)
      end
      f.puts line
    end
    f.puts '</g>'
  end
  f.puts '</svg>'
end

mask_pdf_file = "#{output_dir}/intermediate/#{sprintf("mask.pdf")}"
puts "Exporting mask PDF: #{mask_pdf_file}"
inkscape_export(mask_svg_file, mask_pdf_file)

timestamp = Time.now.strftime('%Y%m%d%H%M%S')

svg_zip_file = "#{output_dir}/#{output['prefix']}#{timestamp}.zip"
puts "Creating zip for all SVG files: #{svg_zip_file}"
sh "cd #{output_dir}/intermediate/ && zip #{File.expand_path(svg_zip_file)} *.svg"

merged_pdf_file = "#{output_dir}/#{output['prefix']}#{timestamp}_RGB.pdf"
puts "Merging all PDF files: #{merged_pdf_file}"
sh "pdfunite #{output_pdf_files.join(' ')} #{mask_pdf_file} #{merged_pdf_file}"

merged_cmyk_pdf_file = "#{output_dir}/#{output['prefix']}#{timestamp}_CMYK.pdf"
puts "Converting to CMYK: #{merged_cmyk_pdf_file}"
sh "gs -dSAFER -dBATCH -dNOPAUSE -dNOCACHE -sDEVICE=pdfwrite -dAutoRotatePages=/None -sColorConversionStrategy=CMYK -dProcessColorModel=/DeviceCMYK -sOutputFile=#{merged_cmyk_pdf_file} #{merged_pdf_file}"
