import { revision } from './revision.js';

const state = window.workflowState = {
  revision, count: 0, updates: 0, documentId: crypto.randomUUID(),
};
const render = () => {
  document.querySelector('#revision').textContent = state.revision;
  document.querySelector('#count').textContent = String(state.count);
};
document.querySelector('#increment').onclick = () => { state.count++; render(); };
document.querySelector('#probe').onclick = async () => {
  const response = await fetch(`/api/probe?document=${state.documentId}`);
  document.querySelector('#result').textContent = (await response.json()).nonce;
};
render();
if (import.meta.hot) {
  import.meta.hot.accept('./revision.js', module => {
    state.revision = module.revision;
    state.updates++;
    render();
    import.meta.hot.send('workflow:applied', {
      revision: state.revision, documentId: state.documentId,
    });
  });
}
