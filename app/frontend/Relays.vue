<script setup vapor lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { api, type RelayRule, type RelayedMessage } from './api'
import ChatPicker from './ChatPicker.vue'

const empty = () => ({ chatId: null as number | null, topicId: null as number | null, title: undefined as string | undefined })
const source = ref(empty())
const target = ref(empty())
const filter = ref('document')
const caption = ref('')
const status = ref('')
const rules = ref<RelayRule[]>([])
const messages = ref<RelayedMessage[]>([])
const error = ref('')
let timer: ReturnType<typeof setInterval>

const refreshRules = async () => { rules.value = await api.relayRules() }
const refreshMessages = async () => { messages.value = await api.relayedMessages(status.value) }
const time = (value: string) => new Date(value).toLocaleString()

async function attempt(action: () => Promise<unknown>) {
  error.value = ''
  try {
    await action()
    await Promise.all([refreshRules(), refreshMessages()])
  } catch (e) {
    error.value = String(e)
  }
}

const create = () => source.value.chatId && target.value.chatId && attempt(() => api.createRelayRule({
  source_chat_id: source.value.chatId!, source_topic_id: source.value.topicId, source_title: source.value.title,
  target_chat_id: target.value.chatId!, target_topic_id: target.value.topicId, target_title: target.value.title,
  filter: filter.value, caption: caption.value || null,
}))
const toggle = (rule: RelayRule) => attempt(() => api.updateRelayRule(rule.id, { enabled: !rule.enabled }))
const remove = (rule: RelayRule) => confirm('Delete this rule?') && attempt(() => api.deleteRelayRule(rule.id))
const retry = (message: RelayedMessage) => attempt(() => api.retryRelayed(message.id))
const retryAll = () => attempt(() => api.retryFailedRelayed())

onMounted(() => { refreshRules(); refreshMessages(); timer = setInterval(refreshMessages, 3000) })
onUnmounted(() => clearInterval(timer))
</script>

<template lang="pug">
section
  h2 Relay
  h3 Rules
  ul
    li(v-for="rule in rules" :key="rule.id")
      label.row
        input(type="checkbox" :checked="rule.enabled" @change="toggle(rule)")
        span {{ rule.source_title ?? rule.source_chat_id }}{{ rule.source_topic_id ? ` #${rule.source_topic_id}` : '' }} → {{ rule.target_title ?? rule.target_chat_id }}{{ rule.target_topic_id ? ` #${rule.target_topic_id}` : '' }} · {{ rule.filter }}
        button(@click.prevent="remove(rule)") Delete
  ChatPicker(label="Relay from" v-model="source")
  ChatPicker(label="Relay to" v-model="target")
  label Messages
    select(v-model="filter")
      option(value="document") documents
      option(value="audio") audio
      option(value="video") video
      option(value="all") all
  label Caption
    input(v-model="caption" placeholder="empty keeps the original caption")
  button(@click="create") Add rule
  p.error(v-if="error") {{ error }}
  h3 Relayed messages
  .row
    select(v-model="status" @change="refreshMessages")
      option(value="") all
      option(value="sent") sent
      option(value="pending") pending
      option(value="failed") failed
    button(@click="retryAll") Retry all failed
  table
    tr(v-for="message in messages" :key="message.id")
      td {{ time(message.created_at) }}
      td {{ message.source_title }} → {{ message.target_title }}
      td
        span(:class="{ error: message.status === 'failed' }") {{ message.status }}
        span.hint  ×{{ message.attempts }}
        div.error(v-if="message.error") {{ message.error }}
      td {{ message.content?.file_name ?? message.content?.summary }}
      td
        a(v-if="message.source_link" :href="message.source_link" target="_blank" rel="noopener") source
        |
        a(v-if="message.target_link" :href="message.target_link" target="_blank" rel="noopener") destination
      td
        button(v-if="message.status === 'failed'" @click="retry(message)") Retry
</template>
