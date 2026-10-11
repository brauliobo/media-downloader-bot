<script setup vapor lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { api, type Replay } from './api'
import ChatPicker from './ChatPicker.vue'

const group = ref({ chatId: null as number | null, topicId: null as number | null })
const parallel = ref(6)
const plan = ref(false)
const jobs = ref<Replay[]>([])
const error = ref('')
let timer: ReturnType<typeof setInterval>

const refresh = async () => { jobs.value = await api.replays() }

async function attempt(action: () => Promise<unknown>) {
  error.value = ''
  try {
    await action()
    await refresh()
  } catch (e) {
    error.value = String(e)
  }
}

const start = () => group.value.chatId && attempt(() => api.replay({ chat_id: group.value.chatId!, parallel: parallel.value, plan: plan.value }))
const stop = (job: Replay) => attempt(() => api.stopReplay(job.id))

onMounted(() => { refresh(); timer = setInterval(refresh, 3000) })
onUnmounted(() => clearInterval(timer))
</script>

<template lang="pug">
section
  h2 Replay
  ChatPicker(label="Group" v-model="group" no-topics)
  label Books in flight
    input(type="number" min="1" v-model.number="parallel")
  label.row
    input(type="checkbox" v-model="plan")
    span Plan only
  button(@click="start") Start
  p.error(v-if="error") {{ error }}
  h3 Replay jobs
  ul
    li(v-for="job in jobs" :key="job.id")
      | {{ job.id }} · {{ job.state }} · {{ job.replayed ?? 0 }} / {{ job.total ?? '?' }} · running {{ job.running ?? 0 }} · skipped {{ job.skipped ?? 0 }}
      span.error(v-if="job.errors?.length")  · {{ job.errors.length }} errors: {{ job.errors[0].error }}
      button(v-if="job.state === 'running'" @click="stop(job)") Stop
</template>
