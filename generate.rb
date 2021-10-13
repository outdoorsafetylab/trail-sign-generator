require 'csv'
require 'fileutils'
require 'rake'
require 'yaml'
require 'base64'

def help
  puts "#{__FILE__} <YAML>"
end

if ARGV.size != 1
  help
  exit 1
end

puts "Reading spec: #{}"
spec_file = ARGV[0]
base_dir = File.dirname(spec_file)
spec = YAML.load(File.read(spec_file))
input = spec['input']
data = File.join(base_dir, input['data'])
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

cols = []
total = 0

puts "Reading data CSV: #{data}"
CSV.foreach(data).with_index do |row, row_num|
  if row_num == 0
    row.each_with_index do |col, col_num|
      cols.push(col)
    end
    puts "Replacing with headers: #{cols}"
  else
    filename = sprintf("sign_%04d.svg", row_num)
    FileUtils.mkdir_p("#{output_dir}/intermediate/")
    intermediate = "#{output_dir}/intermediate/#{filename}"
    puts "Creating intermediate SVG: #{intermediate}"
    File.open(intermediate, "w+") do |f|
      File.foreach(tmpl) do |line|
        row.each_with_index do |col, col_num|
          unless col
            col = ""
          end
          header = cols[col_num]
          line = line.gsub(header, col)
        end
        f.puts(line)
      end
    end
    puts "Vectorizing SVG: #{intermediate}"
    sh "inkscape #{intermediate} --export-plain-svg --export-text-to-path --export-filename=#{intermediate}"
    total += 1
    break if max && total >= max
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
  sh "inkscape #{output_svg_file} --export-plain-svg --export-text-to-path --export-filename=#{output_pdf_file}"
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
sh "inkscape #{mask_svg_file} --export-plain-svg --export-text-to-path --export-filename=#{mask_pdf_file}"

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
