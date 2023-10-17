# frozen_string_literal: true

require_relative "hirefire/utility"

Dir[File.expand_path("../hirefire/**/*.rb", __FILE__)].sort.each do |file|
  next if file.include?("railtie.rb") && !defined?(Rails::Railtie)
  require file
end
