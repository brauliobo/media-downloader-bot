Rails.application.routes.draw do
  root 'dashboard#show'

  namespace :api do
    resources :chats, only: %i[index update] do
      get :topics, on: :member
    end
    resources :forwardings, only: %i[index show create]
    resources :replays, only: %i[index show create] do
      post :stop, on: :member
    end
    resources :relay_rules, only: %i[index create update destroy]
    resources :relayed_messages, only: %i[index show] do
      post :retry, on: :member
      post :retry_failed, on: :collection
    end
  end
end
