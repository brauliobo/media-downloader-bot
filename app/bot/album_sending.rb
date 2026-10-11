module Bot
  # Sends an album batch by batch and answers the messages sent; what a batch is sent with is the bot's own.
  module AlbumSending
    def send_album(msg, text, uploads:, parse_mode: 'MarkdownV2', delete: nil, delete_both: nil, **_params)
      batches = Album.new(uploads, album_caption(msg, text, parse_mode)).batches
      sent    = batches.flat_map { |batch| send_album_batch(msg, batch, parse_mode) }

      finalize_sent_message(msg, message_response(sent.first), delete: delete, delete_both: delete_both)
      sent
    end
  end
end
