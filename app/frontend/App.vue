<script setup vapor lang="ts">
import { ref } from 'vue'
import { token, saveToken } from './api'
import Forwardings from './Forwardings.vue'
import GroupSettings from './GroupSettings.vue'
import Relays from './Relays.vue'
import Replays from './Replays.vue'

const current = ref(token())
const unlock = () => { saveToken(current.value); location.reload() }
</script>

<template lang="pug">
main
  h1 media-downloader-bot
  label Access token
    input(type="password" v-model="current" @keyup.enter="unlock")
  button(@click="unlock") Save
  template(v-if="current")
    Forwardings
    Relays
    Replays
    GroupSettings
</template>

<style>
main { max-width: 40rem; margin: 2rem auto; font-family: sans-serif; }
fieldset, label, section { display: block; margin: 0.75rem 0; }
select, input:not([type=checkbox]) { display: block; width: 100%; margin: 0.25rem 0; }
.row { display: flex; gap: 0.5rem; align-items: center; }
.hint { color: #666; }
.error { color: #b00020; }
</style>
