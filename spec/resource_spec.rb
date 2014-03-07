require 'spec_helper'

describe HireFire::Resource do
  it 'has a default dyno list' do
    described_class.dynos.should be_a(HireFire::DynoList)
  end
  it 'can add dyno list by symbolized type' do
    described_class.dynos = :sidekiq
    described_class.dynos.should be_a(HireFire::DynoLists::Sidekiq)
  end
  it 'can add a dyno list by class' do
    described_class.dynos = HireFire::DynoLists::Sidekiq
    described_class.dynos.should be_a(HireFire::DynoLists::Sidekiq)
  end
  it 'verifies responding to #to_hash' do
    expect {
      described_class.dynos = Array.new
    }.to raise_error(ArgumentError, /to_hash/)
  end
end
