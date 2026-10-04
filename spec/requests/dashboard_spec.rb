require 'rails_helper'

RSpec.describe 'Dashboard', type: :request do
  it 'serves the Vue app mount point with the vite entrypoint' do
    get '/'

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="app"', 'vite-test')
  end
end
