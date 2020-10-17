# frozen_string_literal: true

require "open-uri"
require "openssl"

OpenSSL::SSL.send(:remove_const, :VERIFY_PEER)
OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

def usage
  puts(<<-EOS)

Usage:

  hirefire http://mydomain.com/

Or locally:

  gem install thin
  [bundle exec] thin start -p 3000
  hirefire http://127.0.0.1:3000/

SSL Enabled URLs:

  hirefire https://mydomain.com/

EOS
end

if (url = ARGV[0]).nil?
  usage
else
  begin
    response = open(File.join(url, "hirefire", "test")).read
  rescue
    puts
    puts "Error: Could not connect to: #{url}"
    usage
    exit 1
  end

  if response =~ /HireFire/
    puts response
  else
    puts "Error: Could not find HireFire at #{url}."
    exit 1
  end
end
