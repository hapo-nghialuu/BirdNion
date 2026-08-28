const copyButton = document.querySelector("[data-copy-target]");
const copyStatus = document.querySelector(".copy-status");

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

if (copyButton && copyStatus) {
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

    copyButton.textContent = copied ? "Copied" : "Selected";
    copyStatus.textContent = copied
      ? "Install command copied to clipboard."
      : "Clipboard unavailable. The command is selected for you.";

    window.clearTimeout(resetTimer);
    resetTimer = window.setTimeout(() => {
      copyButton.textContent = "Copy";
      copyStatus.textContent = "";
    }, 2400);
  });
}
