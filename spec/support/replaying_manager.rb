# A manager that records what is replayed. Replaying a message makes the bot answer it with `answers[id]` (default: one audio
# captioned with hashtags); the ones in `failing` raise. `messages` are chat history already there, `gate` blocks a replay until fed.
class ReplayingManager
  attr_reader :replayed, :deleted, :captions, :messages, :replies

  def initialize(failing: [], gate: nil, messages: [], answers: {}, files: {}, active: [], same_file: [])
    @active   = active
    @same_file = same_file
    @files    = files
    @messages = messages
    @answers  = answers
    @deleted  = []
    @replies  = []
    @captions = []
    @gate     = gate
    @failing  = failing
    @replayed = []
    @next_id  = 1_000
  end

  def chat_messages(from_message_id: 0, limit: 20, **) = @messages.sort_by { |m| -m[:id] }.select { |m| from_message_id.zero? || m[:id] < from_message_id }.first(limit)

  def delete_messages(chat_id:, message_ids:) = @deleted.concat(message_ids).tap { @messages.reject! { |m| message_ids.include?(m[:id]) } }

  # `files` maps a message id to { name:, path: } of the document it carries.
  def chat_message(chat_id:, message_id:) = (file = @files[message_id]) && { id: message_id, media: { file_name: file[:name], file_id: message_id } }

  def download_file(file_id) = @files.fetch(file_id)[:path]

  # Every message carries a different file unless `same_file` lists message ids that carry one: a book of the same name and size.
  def message_input(chat_id:, message_id:) = { type: 'document', file_name: "Book #{file_of(message_id)}.pdf", size: 10, inputs: [{ opts: { 'lang' => 'pt' } }] }

  def message_checksum(chat_id:, message_id:) = "sum-#{file_of(message_id)}"

  # `active` are the message ids a worker is still converting.
  def message_job_active?(chat_id:, message_id:) = @active.include?(message_id)

  def message_link(chat_id:, message_id:) = "https://t.me/c/#{chat_id.abs}/#{message_id}"

  def replace_caption(chat_id:, message_id:, from:, to:) = @captions << { chat_id: chat_id, message_id: message_id, from: from, to: to }

  def reply_to_message(chat_id:, message_id:, text:) = @replies << { chat_id: chat_id, message_id: message_id, text: text }

  def file_of(message_id) = @same_file.include?(message_id) ? @same_file.first : message_id

  def replay_message(chat_id:, message_id:)
    @gate&.pop
    raise 'cannot be replayed' if @failing.include?(message_id)

    @replayed << { chat_id: chat_id, id: message_id }
    @answers.fetch(message_id, [{ type: 'Audio', text: "Book #{message_id}\n#Livro #Yoga" }]).each do |answer|
      @messages << { id: @next_id += 1, chat_id: chat_id, reply_to_message_id: message_id, **answer }
    end
  end
end
