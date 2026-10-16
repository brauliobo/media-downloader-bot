Rails.application.routes.draw do
  root 'dashboard#show'

  namespace :api do
    resources :chats, only: %i[index update] do
      get :topics, on: :member
      put :queue, on: :member
    end
    resources :forwardings, only: %i[index show create]
    resources :jobs, only: %i[index show create update] do
      post :stop, on: :member
      post :resume, on: :member
      post :check_languages, on: :member
    end
    resources :job_items, only: %i[index show update] do
      post :apply, on: :member
      post :retry, on: :member
      post :retry_failed, on: :collection
    end
    resources :job_messages, only: %i[index destroy]
    resources :relay_rules, only: %i[index create update destroy]
    resources :relayed_messages, only: %i[index show] do
      post :retry, on: :member
      post :retry_failed, on: :collection
    end
  end
end
