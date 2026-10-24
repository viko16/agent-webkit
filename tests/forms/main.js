import React, { useState } from 'react';
import { createRoot } from 'react-dom/client';
import { createApp, version as vueVersion } from 'vue/dist/vue.esm-bundler.js';

window.frameworkVersions = { react: React.version, vue: vueVersion };
window.formEvents = [];
window.checkboxClicks = [];
document.addEventListener('click', event => {
  if (event.target.type === 'checkbox') window.checkboxClicks.push({ id: event.target.id, trusted: event.isTrusted });
});
document.addEventListener('input', event => {
  window.formEvents.push({ id: event.target.id, trusted: event.isTrusted,
    inputEvent: event instanceof InputEvent, inputType: event.inputType || null });
});
async function save(fields) {
  const response = await fetch('/api/save', { method: 'POST',
    headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(fields) });
  const record = await response.json();
  return response.ok ? `Saved: ${JSON.stringify(record)}` : 'Rejected by server';
}

const h = React.createElement;
function ReactForm() {
  const [text, setText] = useState('');
  const [note, setNote] = useState('');
  const [choice, setChoice] = useState('a');
  const [accepted, setAccepted] = useState(false);
  const [generation, setGeneration] = useState(0);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState('Ready');
  async function submit(event) {
    event.preventDefault(); setBusy(true);
    try { setResult(await save({ framework: 'react', text, note, choice, accepted })); }
    finally { setBusy(false); }
  }
  return h('form', { onSubmit: submit },
    h('h2', null, 'React controlled form'),
    h('input', { id: 'react-text', 'aria-label': 'React text', key: generation, value: text,
      onChange: event => setText(event.target.value) }),
    h('textarea', { id: 'react-note', value: note, onChange: event => setNote(event.target.value) }),
    h('select', { id: 'react-choice', value: choice, onChange: event => setChoice(event.target.value) },
      h('option', { value: 'a' }, 'Alpha'), h('option', { value: 'b' }, 'Beta')),
    h('input', { id: 'react-accepted', type: 'checkbox', checked: accepted,
      onChange: event => setAccepted(event.target.checked) }),
    h('input', { id: 'react-readonly', value: 'locked', readOnly: true }),
    h('fieldset', { disabled: true }, h('input', { id: 'react-disabled', defaultValue: 'locked' })),
    h('button', { id: 'react-replace', type: 'button', onClick: () => setGeneration(generation + 1) }, 'Replace input'),
    h('button', { id: 'react-submit', disabled: busy || !accepted }, 'Save'),
    h('output', { id: 'react-state' }, JSON.stringify({ text, note, choice, accepted, generation })),
    h('output', { id: 'react-result' }, result));
}
createRoot(document.querySelector('#react')).render(h(ReactForm));

createApp({
  data: () => ({ text: '', note: '', choice: 'a', accepted: false, generation: 0, busy: false, result: 'Ready' }),
  methods: {
    async submit() {
      this.busy = true;
      try { this.result = await save({ framework: 'vue', text: this.text, note: this.note,
        choice: this.choice, accepted: this.accepted }); }
      finally { this.busy = false; }
    }
  },
  template: `<form @submit.prevent="submit">
    <h2>Vue v-model form</h2>
    <input id="vue-text" aria-label="Vue text" :key="generation" v-model="text">
    <textarea id="vue-note" v-model="note"></textarea>
    <select id="vue-choice" v-model="choice"><option value="a">Alpha</option><option value="b">Beta</option></select>
    <input id="vue-accepted" type="checkbox" v-model="accepted">
    <input id="vue-readonly" value="locked" readonly>
    <fieldset disabled><input id="vue-disabled" value="locked"></fieldset>
    <button id="vue-replace" type="button" @click="generation++">Replace input</button>
    <button id="vue-submit" :disabled="busy || !accepted">Save</button>
    <output id="vue-state">{{ JSON.stringify({text,note,choice,accepted,generation}) }}</output>
    <output id="vue-result">{{ result }}</output>
  </form>`
}).mount('#vue');

document.querySelector('#rich').addEventListener('input', event => {
  document.querySelector('#rich-result').textContent = event.target.textContent;
});
