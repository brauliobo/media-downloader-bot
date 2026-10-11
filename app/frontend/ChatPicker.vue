<script setup vapor lang="ts">
import { ref, onMounted } from 'vue'
import { api, type Chat, type Topic } from './api'

const props = defineProps<{ label: string; noTopics?: boolean }>()
const picked = defineModel<{ chatId: number | null; topicId: number | null; title?: string }>({ required: true })
const query = ref('')
const chats = ref<Chat[]>([])
const topics = ref<Topic[]>([])

const load = async () => { chats.value = await api.chats(query.value) }
const toId = (value: string) => (value ? Number(value) : null)

async function pickChat(value: string) {
  const chatId = toId(value)
  picked.value = { chatId, topicId: null, title: chats.value.find((chat) => chat.id === chatId)?.title }
  topics.value = chatId && !props.noTopics ? await api.topics(chatId) : []
}

onMounted(load)
</script>

<template lang="pug">
fieldset
  legend {{ label }}
  input(v-model="query" placeholder="search chats, enter to filter" @keyup.enter="load")
  select(:value="picked.chatId ?? ''" @change="pickChat($event.target.value)")
    option(value="") — chat —
    option(v-for="chat in chats" :key="chat.id" :value="chat.id") {{ chat.title }}
  select(v-if="topics.length" :value="picked.topicId ?? ''" @change="picked = { ...picked, topicId: toId($event.target.value) }")
    option(value="") (no topic)
    option(v-for="topic in topics" :key="topic.id" :value="topic.id") {{ topic.name }}
</template>
