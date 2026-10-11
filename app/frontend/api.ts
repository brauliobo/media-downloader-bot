export type Chat = { id: number; title: string; type: string; respond: boolean; options: string }
export type Topic = { id: number; name: string }
export type ChatRef = { chat_id: number; topic_id: number | null }
export type Job = {
  id: string; state: string; source: ChatRef; target: ChatRef; caption: string | null; leave: boolean
  total?: number; sent?: number; skipped?: number; left?: boolean; errors?: { id?: number; error: string }[]
}
export type ForwardingParams = { source: ChatRef; target: ChatRef; filter: string; caption: string; leave: boolean }

export type Replay = {
  id: string; state: string; chat_id: number; parallel: number; plan: boolean
  recover?: boolean; recovered?: number; deleted?: number
  total?: number; replayed?: number; skipped?: number; running?: number; errors?: { id?: number; error: string }[]
}
export type ReplayParams = { chat_id: number; parallel: number; plan: boolean; recover: boolean }

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
  replays: () => call<Replay[]>('/api/replays'),
  replay: (replay: ReplayParams) => call<Replay>('/api/replays', 'POST', { replay }),
  stopReplay: (id: string) => call<Replay>(`/api/replays/${id}/stop`, 'POST'),
  relayRules: () => call<RelayRule[]>('/api/relay_rules'),
  createRelayRule: (relay_rule: RelayRuleParams) => call<RelayRule>('/api/relay_rules', 'POST', { relay_rule }),
  updateRelayRule: (id: number, relay_rule: Partial<RelayRule>) => call<RelayRule>(`/api/relay_rules/${id}`, 'PATCH', { relay_rule }),
  deleteRelayRule: (id: number) => call<RelayRule>(`/api/relay_rules/${id}`, 'DELETE'),
  relayedMessages: (status = '') => call<RelayedMessage[]>(`/api/relayed_messages?status=${status}`),
  retryRelayed: (id: number) => call<RelayedMessage>(`/api/relayed_messages/${id}/retry`, 'POST'),
  retryFailedRelayed: () => call<{ retried: number }>('/api/relayed_messages/retry_failed', 'POST'),
}
