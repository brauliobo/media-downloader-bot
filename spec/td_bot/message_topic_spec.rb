require 'rails_helper'

RSpec.describe TDBot::MessageTopic do
  let(:handler) { Class.new { def create_message_object(_) = SymMash.new }.tap { |klass| klass.prepend described_class }.new }
  let(:message) { Struct.new(:topic_id) }
  let(:forum)   { Struct.new(:forum_topic_id) }

  it 'carries the forum topic the message was posted in' do
    expect(handler.create_message_object(message.new(forum.new(7))).topic_id).to eq(7)
  end

  it 'leaves the topic empty outside forum topics' do
    expect(handler.create_message_object(message.new(nil)).topic_id).to be_nil
  end
end
