module Relay
  # What is shown about a relayed message without opening it.
  module Summary
    EXCERPT = 200

    def self.of(msg)
      kind  = Filter.kind(msg)
      media = msg[kind]
      { type: kind || 'text', file_name: media.try(:file_name), size: size(media, kind), text: msg.text.to_s.truncate(EXCERPT).presence }.compact
    end

    # a TD media wraps its file (document.document), others carry the size themselves
    def self.size(media, kind) = media.try(:file_size) || media.try(kind).try(:size)
  end
end
