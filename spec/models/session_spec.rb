require 'rails_helper'

RSpec.describe Session do
  let(:uid) { 9_000_000_001 }

  around { |example| described_class.db.transaction(rollback: :always, auto_savepoint: true) { example.run } }

  it 'finds or creates by uid with the jsonb defaults' do
    session = described_class.find_or_create uid: uid

    expect(described_class.find_or_create(uid: uid).uid).to eq session.uid
    expect(session.reload).to have_attributes(msg_count: 0, daylog: [], cookies: {}, created_at: be_present)
  end

  it 'persists in-place jsonb changes' do
    session = described_class.find_or_create uid: uid
    session.daylog << {sent_at: Time.now}
    session.msg_count += 1
    session.save

    expect(session.reload).to have_attributes(msg_count: 1)
    expect(session.daylog.size).to eq 1
  end

  it 'is loaded by the worker when sessions are enabled' do
    ENV['DB'] = '1'
    Worker.new SymMash.new(from: {id: uid}), service: nil

    expect(described_class.find(uid: uid)).to have_attributes(msg_count: 1)
  end
end
