<script setup vapor lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { api, type Tracked, type TrackedItem, type TrackedInput } from './api'
import ChatPicker from './ChatPicker.vue'

const STATUSES = ['', 'pending', 'running', 'done', 'failed']
const group = ref({ chatId: null as number | null, topicId: null as number | null })
const parallel = ref(8)
const retryFailed = ref(true)
const jobs = ref<Tracked[]>([])
const selected = ref<Tracked | null>(null)
const status = ref('')
const items = ref<TrackedItem[]>([])
const hashtags = ref<Record<number, string>>({})
const error = ref('')
let timer: ReturnType<typeof setInterval>

const refresh = async () => {
  jobs.value = await api.trackedJobs()
  if (selected.value) {
    items.value = await api.trackedItems(selected.value.id, status.value)
    items.value.forEach(item => hashtags.value[item.id] ??= item.result.hashtags ?? '')
  }
}

async function attempt(action: () => Promise<unknown>) {
  error.value = ''
  try {
    await action()
    await refresh()
  } catch (e) {
    error.value = String(e)
  }
}

const start = () => group.value.chatId && attempt(() => api.startTracked({ kind: 'replay', parallel: parallel.value, params: { chat_id: group.value.chatId!, retry_failed: retryFailed.value } }))
const open = (job: Tracked) => { selected.value = job; hashtags.value = {}; attempt(async () => {}) }
const done = (job: Tracked) => (job.counts.done ?? 0)
const total = (job: Tracked) => Object.values(job.counts).reduce((sum, count) => sum + count, 0)
const active = (job: Tracked) => ['queued', 'running', 'stopping'].includes(job.state)
const changed = (item: TrackedItem) => item.messages.some(message => !message.deleted_at && !message.failed && message.kind !== 'Text' && (message.hashtags ?? '') !== (hashtags.value[item.id] ?? ''))
const opt = ([key, value]: [string, string | number]) => value === 1 ? key : `${key}=${value}`
const inputOf = ({ file_name, type, size, text, inputs = [], error }: TrackedInput) =>
  [file_name ?? text, type, size && `${(size / 1048576).toFixed(1)} MB`, ...inputs.flatMap(({ url, opts = {} }) => [url, ...Object.entries(opts).map(opt)]), error].filter(Boolean).join(' · ')
const save = (item: TrackedItem) => attempt(async () => { await api.editTrackedItem(item.id, hashtags.value[item.id]); await api.applyTrackedItem(item.id) })

onMounted(() => { refresh(); timer = setInterval(refresh, 3000) })
onUnmounted(() => clearInterval(timer))
</script>

<template lang="pug">
section
  h2 Jobs
  ChatPicker(label="Group to replay" v-model="group" no-topics)
  label Books in flight
    input(type="number" min="1" max="10" v-model.number="parallel")
  label.row
    input(type="checkbox" v-model="retryFailed")
    span Retry the failed books (their error replies are deleted first)
  button(@click="start") Start replay
  p.error(v-if="error") {{ error }}
  ul
    li(v-for="job in jobs" :key="job.id")
      strong {{ job.kind }} {{ job.id }}
      span(v-if="job.params.follow")  · group queue
      |  · {{ job.state }} · {{ done(job) }} / {{ total(job) }} done
      span(v-for="(count, name) in job.counts" :key="name")  · {{ name }} {{ count }}
      span.error(v-if="job.error")  · {{ job.error }}
      label.row In flight
        input(type="number" min="1" max="10" :value="job.parallel" @change="attempt(() => api.updateTracked(job.id, { parallel: Number(($event.target as HTMLInputElement).value) }))")
      button(v-if="active(job)" @click="attempt(() => api.stopTracked(job.id))") Stop
      button(v-else @click="attempt(() => api.resumeTracked(job.id))") Resume
      button(v-if="job.counts.failed" @click="attempt(() => api.retryFailedTracked(job.id))") Retry {{ job.counts.failed }} failed
      button(@click="attempt(() => api.checkTrackedLanguages(job.id))") Check languages
      button(@click="open(job)") Items
  template(v-if="selected")
    h3 Items of job {{ selected.id }}
    label Status
      select(v-model="status" @change="refresh")
        option(v-for="s in STATUSES" :key="s" :value="s") {{ s || 'all' }}
    ul
      li(v-for="item in items" :key="item.id")
        | {{ item.key }} · {{ item.status }} · attempts {{ item.attempts }}
        span(v-if="item.result.input")  · {{ inputOf(item.result.input) }}
        span(v-if="item.result.options")  · chat options: {{ item.result.options }}
        span.error(v-if="item.result.lang_check?.mismatch")  · read as {{ item.result.lang_check.lang }}, group is {{ item.result.lang_check.expected }}
        span.error(v-if="item.error")  · {{ item.error }}
        button(v-if="item.status === 'failed'" @click="attempt(() => api.retryTrackedItem(item.id))") Retry
        button(v-if="item.status === 'done'" @click="attempt(() => api.retryTrackedItem(item.id, true))") Delete outputs and reprocess
        .row(v-if="item.status === 'done'")
          input(v-model="hashtags[item.id]" placeholder="#Hashtags posted with the book")
          button(:disabled="!changed(item)" @click="save(item)") Change in chat
        ul
          li(v-for="message in item.messages" :key="message.id")
            | {{ message.kind }} {{ message.message_id }}
            span.error(v-if="message.failed")  · error
            span(v-if="message.deleted_at")  · deleted
            a(v-if="message.link" :href="message.link" target="_blank")  · open
            button(v-if="!message.deleted_at" @click="attempt(() => api.deleteTrackedMessage(message.id))") Delete
</template>
