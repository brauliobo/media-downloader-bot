require_relative '../exts/sym_mash'

module Bot
  module Interface
    # Interface for bot implementations (TDBot, TlBot, MockBot)
    # This module defines the common interface that all bot implementations should provide.
    # Default implementations are provided as mock/stub behavior.

    # Send a message
    # @param msg [Object] The message object
    # @param text [String] The message text
    # @param type [String] The message type (default: 'message')
    # @param parse_mode [String] The parse mode (default: 'MarkdownV2')
    # @param delete [Integer, nil] Time to delete the message
    # @param delete_both [Integer, nil] Time to delete both messages
    # @param params [Hash] Additional parameters
    # @return [SymMash] Response with message_id and text
    def send_message(msg, text, type: 'message', parse_mode: 'MarkdownV2', delete: nil, delete_both: nil, **params)
      puts text
      SymMash.new(result: {message_id: 1}, text: text)
    end

    # Edit a message
    # @param msg [Object] The message object
    # @param id [Integer] The message ID to edit
    # @param text [String, nil] The new text
    # @param type [String] The message type (default: 'text')
    # @param parse_mode [String] The parse mode (default: 'MarkdownV2')
    # @param params [Hash] Additional parameters
    def edit_message(msg, id, text: nil, type: 'text', parse_mode: 'MarkdownV2', **params)
      puts text if text
    end

    # Delete a message
    # @param msg [Object] The message object
    # @param id [Integer] The message ID to delete
    # @param wait [Integer, nil] Time to wait before deleting
    def delete_message(msg, id, wait: nil)
      # no-op by default
    end

    # Download a file
    # @param file_id_or_info [String, Object] The file ID or file info object
    # @param priority [Integer] Download priority (for TDBot, ignored by others)
    # @param offset [Integer] Byte offset (for TDBot, ignored by others)
    # @param limit [Integer] Byte limit (for TDBot, ignored by others)
    # @param synchronous [Boolean] Whether to download synchronously (for TDBot, ignored by others)
    # @param dir [String, nil] Directory to save the file
    # @return [Object, nil] File path or info
    def download_file(file_id_or_info, priority: 32, offset: 0, limit: 0, synchronous: true, dir: nil)
      nil
    end

  end

  # Mock bot implementation for testing and standalone scripts
  # This class includes Bot::Interface and provides a minimal implementation
  # that prints messages to stdout instead of sending them to Telegram
  class Mock
    include Interface
  end
end

