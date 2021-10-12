require 'csv'
require 'fileutils'
require 'rake'

def help
  puts "#{__FILE__} <Data CSV> <Template SVG>"
end

if ARGV.size != 2
  help
  exit 1
end

data = ARGV[0]
tmpl = ARGV[1]
outputDir = File.basename(tmpl, File.extname(tmpl))

cols = []

puts "Reading data CSV: #{data}"
CSV.foreach(data).with_index do |row, row_num|
  if row_num == 0
    row.each_with_index do |col, col_num|
      cols.push(col)
    end
    puts "Replacing with headers: #{cols}"
  else
    filename = sprintf("%04d.svg", row_num)
    FileUtils.mkdir_p("#{outputDir}/intermediate/")
    intermediate = "#{outputDir}/intermediate/#{filename}"
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
    FileUtils.mkdir_p("#{outputDir}/vectorized/")
    vectorized = "#{outputDir}/vectorized/#{filename}"
    puts "Creating vectorized SVG: #{vectorized}"
    sh "inkscape #{intermediate} --export-plain-svg --export-text-to-path --export-filename=#{vectorized}"
  end
end
