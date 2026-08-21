require 'spec_helper'

RSpec.describe Bot::UserQueue do
  before { described_class.instance_variable_set(:@instance, nil) }

  let(:bot)          { Bot::Mock.new }
  let(:admin_id)     { Bot::MsgHelpers::ADMIN_CHAT_ID }
  let(:non_admin_id) { 424242 }

  def msg_for(user_id)
    SymMash.new from: { id: user_id }, chat: { id: user_id }, text: ''
  end

  describe '#with_user_slot' do
    it 'runs stop commands without waiting for an occupied user slot' do
      queue = described_class.instance
      queue.acquire(non_admin_id)
      ran = false
      msg = msg_for(non_admin_id)
      msg.text = '/stop'

      queue.with_user_slot(bot, msg) { ran = true }

      expect(ran).to be(true)
    ensure
      queue&.release(non_admin_id)
    end

    it 'serializes concurrent jobs from the same non-admin user' do
      queue   = described_class.instance
      started = Queue.new
      gate    = Queue.new
      order   = []

      threads = 3.times.map do |i|
        Thread.new do
          queue.with_user_slot(bot, msg_for(non_admin_id)) do
            started << i
            gate.pop
            order << i
          end
        end
      end

      expect(started.pop).to eq(0)
      sleep 0.1
      expect(started.size).to eq(0)

      gate << :go; expect(started.pop).to eq(1)
      sleep 0.1
      expect(started.size).to eq(0)

      gate << :go; expect(started.pop).to eq(2)
      gate << :go

      threads.each(&:join)
      expect(order).to eq([0, 1, 2])
    end

    it 'lets admins run jobs concurrently' do
      queue = described_class.instance
      peak  = 0
      pmtx  = Mutex.new
      gate  = Queue.new
      n     = 0
      nmtx  = Mutex.new

      threads = 3.times.map do
        Thread.new do
          queue.with_user_slot(bot, msg_for(admin_id)) do
            cur = nmtx.synchronize { n += 1 }
            pmtx.synchronize { peak = cur if cur > peak }
            gate.pop
          end
        end
      end

      sleep 0.2
      3.times { gate << :go }
      threads.each(&:join)
      expect(peak).to eq(3)
    end

    it 'posts a Queued status while waiting and keeps it on acquire' do
      queue = described_class.instance
      queue.acquire(non_admin_id)

      sent = []
      allow(bot).to receive(:send_message) { |_, t| sent << t; SymMash.new(message_id: 99) }
      expect(bot).not_to receive(:delete_message)
      msg = msg_for(non_admin_id)

      t = Thread.new { queue.with_user_slot(bot, msg) { sleep 0.05 } }
      sleep 0.1

      expect(sent.last).to include(described_class::QUEUED_MSG)
      expect(msg.resp.message_id).to eq(99)

      queue.release(non_admin_id)
      t.join

    end

    it 'releases the slot when the block raises' do
      queue = described_class.instance
      expect { queue.with_user_slot(bot, msg_for(non_admin_id)) { raise 'boom' } }.to raise_error('boom')
      expect(queue.queued?(non_admin_id)).to be false
    end

  end
end
