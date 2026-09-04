# frozen_string_literal: true

Dir[File.expand_path("hirefire/**/*.rb", __dir__)].sort.each do |file|
  next if file.end_with?("railtie.rb") && !defined?(Rails::Railtie)
  require file
end
