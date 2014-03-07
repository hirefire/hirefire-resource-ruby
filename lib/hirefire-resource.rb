# encoding: utf-8

HIREFIRE_PATH = File.expand_path("../hirefire", __FILE__)

%w[json_formatter middleware resource dyno_list].each do |file|
  require "#{HIREFIRE_PATH}/#{file}"
end

%w[delayed_job resque sidekiq qu qc].each do |file|
  require "#{HIREFIRE_PATH}/macro/#{file}"
end

%w[sidekiq].each do |file|
  require "#{HIREFIRE_PATH}/dyno_lists/#{file}"
end

require "#{HIREFIRE_PATH}/railtie" if defined?(Rails::Railtie)

