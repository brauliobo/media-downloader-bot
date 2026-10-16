export type Chat = { id: number; title: string; type: string; respond: boolean; options: string }
export type Topic = { id: number; name: string }
export type ChatRef = { chat_id: number; topic_id: number | null }
export type Job = {
  id: string; state: string; source: ChatRef; target: ChatRef; caption: string | null; leave: boolean
  total?: number; sent?: number; skipped?: number; left?: boolean; errors?: { id?: number; error: string }[]
}
export type ForwardingParams = { source: ChatRef; target: ChatRef; filter: string; caption: string; leave: boolean }

export type Tracked = {
  id: number; kind: string; state: string; parallel: number; error: string | null
  params: { chat_id?: number; retry_failed?: boolean }; counts: Record<string, number>
  created_at: string; started_at: string | null; finished_at: string | null
}
export type TrackedParams = { kind: string; parallel: number; params: { chat_id: number; retry_failed: boolean } }
export type TrackedMessage = {
  id: number; job_item_id: number; chat_id: number; message_id: number; kind: string | null; failed: boolean
  text: string | null; hashtags: string | null; link: string | null; deleted_at: string | null
}
export type TrackedInput = {
  type?: string; file_name?: string; size?: number; text?: string; error?: string
  inputs?: { url?: string; opts?: Record<string, string | number> }[]
}
export type TrackedItem = {
  id: number; job_id: number; key: string; status: 'pending' | 'running' | 'done' | 'failed'; attempts: number; error: string | null
  result: { hashtags?: string; options?: string; input?: TrackedInput }; finished_at: string | null; messages: TrackedMessage[]
}

export type RelayRuleParams = {
  source_chat_id: number; source_topic_id: number | null; source_title?: string
  target_chat_id: number; target_topic_id: number | null; target_title?: string
  filter: string; caption: string | null
}
export type RelayRule = RelayRuleParams & { id: number; enabled: boolean }
export type RelayedMessage = {
  id: number; relay_rule_id: number; status: 'pending' | 'sent' | 'failed'; attempts: number; error: string | null
  source_title: string | null; target_title: string | null; source_link: string | null; target_link: string | null
  content: { file_name?: string; summary?: string }; created_at: string
}

const tokenKey = 'bot_http_token'

export const token = () => localStorage.getItem(tokenKey) ?? ''
export const saveToken = (value: string) => localStorage.setItem(tokenKey, value)

async function call<T>(path: string, method = 'GET', body?: unknown): Promise<T> {
  const response = await fetch(path, {
    method,
    headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  if (!response.ok) throw new Error(`${method} ${path}: ${response.status} ${await response.text()}`)
  return response.json()
}

export const api = {
  chats: (query = '') => call<Chat[]>(`/api/chats?q=${encodeURIComponent(query)}`),
  topics: (chatId: number) => call<Topic[]>(`/api/chats/${chatId}/topics`),
  setRespond: (chat: Chat, respond: boolean) => call(`/api/chats/${chat.id}`, 'PATCH', { respond, title: chat.title }),
  setOptions: (chat: Chat, options: string) => call(`/api/chats/${chat.id}`, 'PATCH', { options, title: chat.title }),
  jobs: () => call<Job[]>('/api/forwardings'),
  forward: (forwarding: ForwardingParams) => call<Job>('/api/forwardings', 'POST', { forwarding }),
  trackedJobs: () => call<Tracked[]>('/api/jobs'),
  startTracked: (job: TrackedParams) => call<Tracked>('/api/jobs', 'POST', { job }),
  updateTracked: (id: number, job: { parallel: number }) => call<Tracked>(`/api/jobs/${id}`, 'PATCH', { job }),
  stopTracked: (id: number) => call<Tracked>(`/api/jobs/${id}/stop`, 'POST'),
  resumeTracked: (id: number) => call<Tracked>(`/api/jobs/${id}/resume`, 'POST'),
  trackedItems: (jobId: number, status = '') => call<TrackedItem[]>(`/api/job_items?job_id=${jobId}&status=${status}`),
  editTrackedItem: (id: number, hashtags: string) => call<TrackedItem>(`/api/job_items/${id}`, 'PATCH', { job_item: { hashtags } }),
  applyTrackedItem: (id: number) => call<TrackedItem>(`/api/job_items/${id}/apply`, 'POST'),
  retryTrackedItem: (id: number) => call<{ retried: number }>(`/api/job_items/${id}/retry`, 'POST'),
  retryFailedTracked: (jobId: number) => call<{ retried: number }>(`/api/job_items/retry_failed?job_id=${jobId}`, 'POST'),
  deleteTrackedMessage: (id: number) => call<TrackedMessage>(`/api/job_messages/${id}`, 'DELETE'),
  relayRules: () => call<RelayRule[]>('/api/relay_rules'),
  createRelayRule: (relay_rule: RelayRuleParams) => call<RelayRule>('/api/relay_rules', 'POST', { relay_rule }),
  updateRelayRule: (id: number, relay_rule: Partial<RelayRule>) => call<RelayRule>(`/api/relay_rules/${id}`, 'PATCH', { relay_rule }),
  deleteRelayRule: (id: number) => call<RelayRule>(`/api/relay_rules/${id}`, 'DELETE'),
  relayedMessages: (status = '') => call<RelayedMessage[]>(`/api/relayed_messages?status=${status}`),
  retryRelayed: (id: number) => call<RelayedMessage>(`/api/relayed_messages/${id}/retry`, 'POST'),
  retryFailedRelayed: () => call<{ retried: number }>('/api/relayed_messages/retry_failed', 'POST'),
}
