function copyFromSelection(target) {
  const selection = window.getSelection();
  if (!selection) return false;

  const range = document.createRange();
  range.selectNodeContents(target);
  selection.removeAllRanges();
  selection.addRange(range);

  try {
    const copied = document.execCommand("copy");
    if (copied) selection.removeAllRanges();
    return copied;
  } catch {
    return false;
  }
}

// The page has more than one install command (hero + install panel); each
// button reports into the status line named by its data-status-target.
for (const copyButton of document.querySelectorAll("[data-copy-target]")) {
  const copyStatus = document.getElementById(copyButton.dataset.statusTarget);
  if (!copyStatus) continue;

  let resetTimer;

  copyButton.addEventListener("click", async () => {
    const target = document.getElementById(copyButton.dataset.copyTarget);
    if (!target) return;

    let copied = false;
    try {
      await navigator.clipboard.writeText(target.textContent.trim());
      copied = true;
    } catch {
      copied = copyFromSelection(target);
    }

    copyButton.textContent = copied
      ? copyButton.dataset.copiedLabel
      : copyButton.dataset.selectedLabel;
    copyStatus.textContent = copied
      ? copyButton.dataset.copiedStatus
      : copyButton.dataset.selectedStatus;

    window.clearTimeout(resetTimer);
    resetTimer = window.setTimeout(() => {
      copyButton.textContent = copyButton.dataset.copyLabel;
      copyStatus.textContent = "";
    }, 2400);
  });
}
