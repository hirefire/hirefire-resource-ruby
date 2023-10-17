# frozen_string_literal: true

# Requires all Ruby files in the 'hirefire' directory and its subdirectories.
# It conditionally requires 'railtie.rb' only if the Rails environment is detected.
# This setup ensures that HireFire components are loaded appropriately depending on
# the presence of Rails, allowing for proper integration in both Rails and non-Rails contexts.
Dir[File.expand_path("../hirefire/**/*.rb", __FILE__)].sort.each do |file|
  next if file.include?("railtie.rb") && !defined?(Rails::Railtie)
  require file
end
