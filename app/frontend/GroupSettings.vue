<script setup vapor lang="ts">
import { ref, onMounted } from 'vue'
import { api, type Chat, type Tracked } from './api'

const GROUP_TYPES = ['BasicGroup', 'Supergroup']
const groups = ref<Chat[]>([])

async function toggle(group: Chat, respond: boolean) {
  await api.setRespond(group, respond)
  group.respond = respond
}

const saveOptions = (group: Chat) => api.setOptions(group, group.options.trim())
const setQueue = async (group: Chat, enabled: boolean, parallel?: number) => { const job = await api.setQueue(group, enabled, parallel); group.queue = enabled ? job : null }
const pause = async (group: Chat) => { group.queue = await api.stopTracked(group.queue!.id) }
const resume = async (group: Chat) => { group.queue = await api.resumeTracked(group.queue!.id) }
const paused = (queue: Tracked) => !['queued', 'running'].includes(queue.state)
const count = (queue: Tracked, status: string) => queue.counts[status] ?? 0

onMounted(async () => { groups.value = (await api.chats()).filter(chat => GROUP_TYPES.includes(chat.type)) })
</script>

<template lang="pug">
section
  h2 Groups the bot responds to
  p.hint Groups are ignored until enabled here. Default options (e.g. lang=pt hashtags) apply to every message of the group unless typed. With a queue, what is posted in the group waits in line and runs a few at a time instead of all at once.
  div(v-for="group in groups" :key="group.id")
    .row
      label.row
        input(type="checkbox" :checked="group.respond" @change="toggle(group, $event.target.checked)")
        span {{ group.title }}
      input(v-model="group.options" placeholder="default options" @change="saveOptions(group)")
    .row(v-if="group.respond")
      label.row
        input(type="checkbox" :checked="!!group.queue" @change="setQueue(group, $event.target.checked)")
        span Queue
      template(v-if="group.queue")
        label.row In flight
          input(type="number" min="1" max="10" :value="group.queue.parallel" @change="setQueue(group, true, Number($event.target.value))")
        span {{ group.queue.state }} · waiting {{ count(group.queue, 'pending') }} · running {{ count(group.queue, 'running') }} · done {{ count(group.queue, 'done') }} · failed {{ count(group.queue, 'failed') }}
        button(v-if="paused(group.queue)" @click="resume(group)") Resume
        button(v-else @click="pause(group)") Pause
</template>
