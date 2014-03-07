require 'spec_helper'

describe HireFire::DynoList do
  it 'can add dynos and generate a hash' do
    dynamic = 0
    subject.add(:queue1){ 1 }
    subject.add(:queue2){ 2 }
    subject.add(:queue3){ dynamic += 1 }
    subject.to_hash[:queue1].should == 1
    subject.to_hash[:queue2].should == 2
    subject.to_hash[:queue3].should == 3
  end
  it 'can generate json from to_hash' do
    subject.add(:queue1){ 1 }
    subject.add(:queue2){ 2 }
    subject.add(:queue3){  }
    subject.should_receive(:to_hash).and_call_original
    json = subject.to_json
    json.should match(/{"name":"queue1","quantity":1}/)
    json.should match(/{"name":"queue3","quantity":null}/)
    json.should match(/^\[.+\]$/)
  end
end

