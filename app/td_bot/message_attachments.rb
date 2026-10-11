module TDBot
  # Prepended to TD::MessageHandler: the audio, video and document of an incoming message read like the ones of
  # any other bot (file_name, mime_type, file_size, and nil for what they do not have), not as TDLib types.
  module MessageAttachments
    KINDS = %i[audio video document].freeze

    def create_message_object(orig_msg)
      super.tap { |msg| KINDS.each { |kind| msg[kind] = attachment(msg[kind], kind) if msg[kind] } }
    end

    private

    def attachment(media, kind) = SymMash.new(media.to_h).tap { |attachment| attachment.file_size = media.public_send(kind).size }
  end
end
