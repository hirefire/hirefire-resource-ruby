require 'spec_helper'

describe HireFire::JsonFormatter do
  it 'can generate json from to_hash' do
    hash = {
      :queue1 => 1,
      :queue2 => 2,
      :queue3 => nil,
    }
    json = subject.to_json(hash)
    json.should match(/{"name":"queue1","quantity":1}/)
    json.should match(/{"name":"queue3","quantity":null}/)
    json.should match(/^\[.+\]$/)
  end
end

