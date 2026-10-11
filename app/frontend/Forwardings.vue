<script setup vapor lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { api, type Job } from './api'
import ChatPicker from './ChatPicker.vue'

const empty = () => ({ chatId: null as number | null, topicId: null as number | null })
const source = ref(empty())
const target = ref(empty())
const filter = ref('document')
const caption = ref('lang=pt')
const leave = ref(false)
const jobs = ref<Job[]>([])
const error = ref('')
let timer: ReturnType<typeof setInterval>

const ref_ = (picked: { chatId: number | null; topicId: number | null }) => ({ chat_id: picked.chatId!, topic_id: picked.topicId })
const refresh = async () => { jobs.value = await api.jobs() }

async function start() {
  const warning = leave.value ? ' and LEAVE the source chat afterwards' : ''
  if (!source.value.chatId || !target.value.chatId || !confirm(`Forward the messages${warning}?`)) return
  error.value = ''
  try {
    await api.forward({ source: ref_(source.value), target: ref_(target.value), filter: filter.value, caption: caption.value, leave: leave.value })
    await refresh()
  } catch (e) {
    error.value = String(e)
  }
}

onMounted(() => { refresh(); timer = setInterval(refresh, 3000) })
onUnmounted(() => clearInterval(timer))
</script>

<template lang="pug">
section
  h2 Forward
  ChatPicker(label="Source" v-model="source")
  ChatPicker(label="Target" v-model="target")
  label Messages
    select(v-model="filter")
      option(value="document") documents
      option(value="audio") audio
      option(value="video") video
      option(value="all") all
  label Caption
    input(v-model="caption" placeholder="empty keeps the original caption")
  label.row
    input(type="checkbox" v-model="leave")
    span Leave the source chat when everything was forwarded
  button(@click="start") Forward
  p.error(v-if="error") {{ error }}
  h3 Jobs
  ul
    li(v-for="job in jobs" :key="job.id")
      | {{ job.id }} · {{ job.state }} · sent {{ job.sent ?? 0 }} / {{ job.total ?? '?' }} · skipped {{ job.skipped ?? 0 }}
      span(v-if="job.left")  · left source
      span.error(v-if="job.errors?.length")  · {{ job.errors.length }} errors: {{ job.errors[0].error }}
</template>
