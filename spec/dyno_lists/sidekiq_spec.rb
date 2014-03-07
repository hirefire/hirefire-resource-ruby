require 'spec_helper'

describe HireFire::DynoLists::Sidekiq do
  let(:queues){
    {
      'a' => 1,
      'c' => 3,
      'd' => 4,
      'e' => 2,
      'd.1' => 5,
      'd.2' => 6,
      'f' => 7
    }
  }
  it 'can add dynos and generate a hash' do
    subject.add(:queue1, %w[a b c])
    subject.add(:queue2 => [/d/, :e, /g/])
    subject.add(:queue3 => /f/)
    subject.add(:queue4) do
      4
    end
    HireFire::Macro::Sidekiq.should_receive(:queue_list).exactly(4).times.and_return(queues)
    subject.to_hash[:queue1].should == 4
    subject.to_hash[:queue2].should == 17
    subject.to_hash[:queue3].should == 7
    subject.to_hash[:queue4].should == 4
  end
end
