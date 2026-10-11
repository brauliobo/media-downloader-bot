<script setup vapor lang="ts">
import { ref, onMounted } from 'vue'
import { api, type Chat } from './api'

const GROUP_TYPES = ['BasicGroup', 'Supergroup']
const groups = ref<Chat[]>([])

async function toggle(group: Chat, respond: boolean) {
  await api.setRespond(group, respond)
  group.respond = respond
}

const saveOptions = (group: Chat) => api.setOptions(group, group.options.trim())

onMounted(async () => { groups.value = (await api.chats()).filter(chat => GROUP_TYPES.includes(chat.type)) })
</script>

<template lang="pug">
section
  h2 Groups the bot responds to
  p.hint Groups are ignored until enabled here. Default options (e.g. lang=pt hashtags) apply to every message of the group unless typed.
  .row(v-for="group in groups" :key="group.id")
    label.row
      input(type="checkbox" :checked="group.respond" @change="toggle(group, $event.target.checked)")
      span {{ group.title }}
    input(v-model="group.options" placeholder="default options" @change="saveOptions(group)")
</template>
