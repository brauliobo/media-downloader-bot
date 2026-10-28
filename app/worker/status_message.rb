class Worker
  # The message a job keeps up to date while it runs, and the cancel button it carries.
  module StatusMessage
    private

    def init_status
      return if @st

      @st = Bot::Status.new(on_empty: -> { delete_status_message }) do |text, *args, **params|
        params[:cancel_job] = job_id if job_id && !params.key?(:cancel_job)
        @status_update = [text, args, params]
        edit_status text, args, params, force: params[:cancel_job] == false
      end
      initial_params = job_id ? {cancel_job: job_id} : {}
      initial_text   = 'Downloading metadata...'
      @status_update = [initial_text, [], initial_params]
      text    = Bot::MsgHelpers.me(initial_text)
      drop_stale_status
      resumed = msg.resp&.message_id && edit_message(msg, msg.resp.message_id, text: text, force: true, **initial_params)
      return if resumed

      msg.resp = send_message msg, text, **initial_params
      BotJob.remember_status(job_id, msg.resp.message_id) if job_id
    end

    # The status of an earlier attempt goes on being the job's only while its files are there: the work continues from them. A job taken
    # again without them (a reboot clears the tmpfs) starts over, and a new message says so instead of the old one showing the
    # progress of a run that is gone. The "Queued" reply of a first attempt is the status to edit, as it always was.
    def drop_stale_status
      return unless msg.resp&.message_id && retaken? && !@kept_files

      delete_message(msg, msg.resp.message_id, wait: 0)
      msg.resp = nil
    end

    def retaken? = job_id && BotJob.where(id: job_id).get(:attempts).to_i > 1

    def delete_status_message
      delete_message(msg, msg.resp.message_id, wait: 0) if msg.resp&.message_id
      @status_deleted = true
    end

    def clear_cancel_button
      return unless job_id && !@status_deleted && @status_update && msg.resp&.message_id

      text, args, params = @status_update
      edit_status text, args, params.merge(cancel_job: false), force: true
    end

    def edit_status(text, args, params, force:)
      edit_message msg, msg.resp.message_id, *args, text: (params[:parse_mode] ? text : Bot::MsgHelpers.me(text)),
                   force: force, **params
    rescue
      # Retry without MarkdownV2 so error messages with special chars still display
      edit_message(msg, msg.resp.message_id, text: text, force: force, parse_mode: nil, cancel_job: params[:cancel_job]) rescue nil
    end
  end
end
