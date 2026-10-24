require 'rails_helper'

RSpec.describe Audiobook::HtmlToPdf do
  def run_pdf(stderr, pdf_path)
    allow(Sh).to receive(:run).and_return(['', stderr, instance_double(Process::Status, success?: true)])
    described_class.run_pdf!(['chromium'], 'chromium pdf', pdf_path)
  end

  it 'names the missing PDF instead of the DBus errors chromium prints without a session bus' do
    noise = "[1:1:1022/161732.833063:ERROR:dbus/bus.cc:405] Failed to connect to the bus\n" * 3

    expect { run_pdf(noise, '/nonexistent/out.pdf') }.to raise_error(Sh::Error, 'chromium pdf: wrote no PDF')
  end

  it 'keeps the errors that are not DBus ones' do
    stderr = "[1:1:1:ERROR:dbus/bus.cc:405] Failed to connect\n[1:1:1:ERROR:net] ERR_FILE_NOT_FOUND\n"

    expect { run_pdf(stderr, '/nonexistent/out.pdf') }.to raise_error(Sh::Error, 'chromium pdf: [1:1:1:ERROR:net] ERR_FILE_NOT_FOUND')
  end
end
