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
output_page_files = []

for i in 1..num_pages do
  page_file = "#{output_dir}/intermediate/#{sprintf("page_%02d.svg", i)}"
  puts "Creating page SVG: #{page_file}"
  File.open(page_file, "w+") do |f|
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
        slot['gsub'].each do |k,v|
          line = line.gsub(k, v)
        end
        f.puts line
      end
      f.puts '</g>'
      break if n >= total
    end
    f.puts '</svg>'
  end
  output_page_file = "#{output_dir}/intermediate/#{sprintf("page_%02d.pdf", i)}"
  puts "Exporting page PDF: #{output_page_file}"
  sh "inkscape #{page_file} --export-plain-svg --export-text-to-path --export-filename=#{output_page_file}"
  output_page_files.push output_page_file
end

mask_file = "#{output_dir}/intermediate/mask.svg"
puts "Creating mask SVG: #{mask_file}"
File.open(mask_file, "w+") do |f|
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
      f.puts line.gsub('<svg', '<g').gsub('</svg>', '</g>')
    end
    f.puts '</g>'
  end
  f.puts '</svg>'
end

output_mask_file = "#{output_dir}/intermediate/#{sprintf("mask.pdf")}"
puts "Exporting mask PDF: #{output_mask_file}"
sh "inkscape #{mask_file} --export-plain-svg --export-text-to-path --export-filename=#{output_mask_file}"

timestamp = Time.now.strftime('%Y%m%d%H%M%S')
output_file = "#{output_dir}/#{output['prefix']}#{timestamp}_RGB.pdf"
puts "Merging all PDF files: #{output_file}"
sh "pdfunite #{output_page_files.join(' ')} #{output_mask_file} #{output_file}"

output_cmyk_file = "#{output_dir}/#{output['prefix']}#{timestamp}_CMYK.pdf"
puts "Converting to CMYK: #{output_cmyk_file}"
sh "gs -dSAFER -dBATCH -dNOPAUSE -dNOCACHE -sDEVICE=pdfwrite -dAutoRotatePages=/None -sColorConversionStrategy=CMYK -dProcessColorModel=/DeviceCMYK -sOutputFile=#{output_cmyk_file} #{output_file}"
