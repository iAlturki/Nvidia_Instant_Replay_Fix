// Copyright (c) 2026 iAlturki. SPDX-License-Identifier: CC-BY-NC-SA-4.0
'use strict';
const copyButton = document.getElementById('copy-prompt');
const promptText = document.getElementById('setup-prompt');
const copyStatus = document.getElementById('copy-status');

copyButton.addEventListener('click', async () => {
  copyButton.disabled = true;
  try {
    if (!navigator.clipboard?.writeText) throw new Error('Clipboard API unavailable');
    await navigator.clipboard.writeText(promptText.value);
    copyButton.querySelector('.copy-label').textContent = 'Copy again';
    copyStatus.textContent = 'Setup prompt copied. Paste it into your AI agent.';
    copyStatus.classList.add('success');
  } catch {
    document.getElementById('prompt-details').open = true;
    promptText.focus();
    promptText.select();
    copyStatus.textContent = 'Automatic copying was blocked. The prompt is selected — press Ctrl+C or ⌘C, then paste it into your agent.';
    copyStatus.classList.remove('success');
  } finally {
    copyButton.disabled = false;
  }
});
