require 'rails_helper'

RSpec.describe JobItem, '.untagged' do
  let!(:job) { Job.create(kind: 'replay', state: 'completed', parallel: 1, params: Sequel.pg_jsonb(chat_id: -200)) }

  around { |example| Job.db.transaction(rollback: :always, auto_savepoint: true) { example.run } }

  def item(key, result: { options: 'lang=pt hashtags' }, status: 'done', books: [{ hashtags: '' }])
    described_class.create(job_id: job.id, kind: 'replay', key: "-200:#{key}", status: status, result: Sequel.pg_jsonb(result)).tap do |created|
      created.record_messages(books.each_with_index.map { |book, index| { chat_id: -200, message_id: key * 10 + index, kind: 'Audio', failed: false, **book } })
    end
  end

  def untagged = described_class.untagged.select_map(:key)

  it 'has the books posted without the hashtags the chat options asked for, or the message typed' do
    item(1)
    item(2, result: { options: '', input: { inputs: [{ opts: { hashtags: 1 } }] } })
    item(3, result: { options: 'hts' })

    expect(untagged).to contain_exactly('-200:1', '-200:2', '-200:3')
  end

  it 'leaves the books that did not ask for hashtags' do
    item(1, result: { options: 'lang=pt' })
    item(2, result: { options: '', input: { inputs: [{ opts: { lang: 'pt' } }] } })

    expect(untagged).to be_empty
  end

  it 'leaves the books with hashtags in any of their live media' do
    item(1, books: [{ hashtags: '' }, { hashtags: '#Livro' }])

    expect(untagged).to be_empty
  end

  it 'leaves the items with no live book posted, and the ones not done' do
    item(1, books: [{ failed: true }])
    item(2, books: [{ deleted_at: Time.now }])
    item(3, books: [])
    item(4, status: 'pending')

    expect(untagged).to be_empty
  end
end
