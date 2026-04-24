// NinjaOne Terminal Popout
// Injects a popout button into the terminal header that moves the entire
// terminal modal into a Document Picture-in-Picture window so it can be
// dragged to another monitor.

(() => {
  'use strict';

  const MODAL_SELECTOR = '.maccommand-line-modal';
  const TERMINAL_SELECTOR = '.terminal.xterm';
  const BUTTON_ID = 'ninja-popout-btn';

  let pipWindow = null;
  let restoreAnchor = null; // { parent, nextSibling } for putting modal back

  // Pop out icon — two overlapping squares, monochrome, sized to match Ninja's header icons.
  const POPOUT_SVG = `
    <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
      <rect x="2" y="4" width="9" height="9" rx="1"/>
      <path d="M6 2h8v8"/>
    </svg>
  `;

  function findHeaderIconGroup(modal) {
    // Each header icon button is wrapped in its own <span class="float-right
    // data-ninja-tooltip-trigger">. The *parent* of those spans is the row
    // container we want to insert a peer into.
    const firstWrapper = modal.querySelector('.float-right');
    if (firstWrapper && firstWrapper.parentElement) {
      return firstWrapper.parentElement;
    }

    // Fallback: find any parent with >=2 sibling buttons.
    const buttons = modal.querySelectorAll('button');
    for (const btn of buttons) {
      const parent = btn.parentElement;
      if (!parent) continue;
      const siblingButtons = parent.querySelectorAll(':scope > button');
      if (siblingButtons.length >= 2) {
        return parent;
      }
    }
    return null;
  }

  function createPopoutButton() {
    const btn = document.createElement('button');
    btn.id = BUTTON_ID;
    btn.type = 'button';
    btn.title = 'Pop out terminal to a separate window';
    btn.setAttribute('aria-label', 'Pop out terminal');
    btn.innerHTML = POPOUT_SVG;

    // Match the visual style of neighboring Ninja icon buttons.
    // The parent <span class="float-right"> handles outer spacing, so keep
    // our button's own styling minimal.
    Object.assign(btn.style, {
      background: 'transparent',
      border: 'none',
      cursor: 'pointer',
      padding: '4px',
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      color: 'inherit',
      opacity: '0.8',
      borderRadius: '4px',
      verticalAlign: 'middle'
    });
    btn.addEventListener('mouseenter', () => { btn.style.opacity = '1'; });
    btn.addEventListener('mouseleave', () => { btn.style.opacity = '0.8'; });

    btn.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      popOut();
    });

    return btn;
  }

  function injectButton() {
    const modal = document.querySelector(MODAL_SELECTOR);
    if (!modal) return;
    if (modal.querySelector('#' + BUTTON_ID)) return; // already injected

    const iconGroup = findHeaderIconGroup(modal);
    if (!iconGroup) return;

    // Find one of Ninja's existing wrapper spans to clone its classes,
    // so our wrapper inherits the same spacing/layout rules as its peers.
    const existingWrapper = iconGroup.querySelector('.float-right');
    const wrapper = document.createElement('span');
    if (existingWrapper) {
      wrapper.className = existingWrapper.className;
    } else {
      wrapper.className = 'float-right';
    }
    wrapper.setAttribute('data-ninja-popout-wrapper', 'true');

    const btn = createPopoutButton();
    wrapper.appendChild(btn);

    // Insert as first child so it sits to the left of the keyboard icon.
    iconGroup.insertBefore(wrapper, iconGroup.firstChild);
  }

  function copyStyles(targetDoc) {
    for (const sheet of document.styleSheets) {
      try {
        const cssText = [...sheet.cssRules].map(r => r.cssText).join('\n');
        const style = targetDoc.createElement('style');
        style.textContent = cssText;
        targetDoc.head.appendChild(style);
      } catch (_err) {
        // Cross-origin stylesheet — link it instead.
        if (sheet.href) {
          const link = targetDoc.createElement('link');
          link.rel = 'stylesheet';
          link.href = sheet.href;
          targetDoc.head.appendChild(link);
        }
      }
    }
  }

  async function popOut() {
    if (!('documentPictureInPicture' in window)) {
      alert('Your browser does not support Document Picture-in-Picture. Use a recent Chrome/Edge.');
      return;
    }

    if (pipWindow && !pipWindow.closed) {
      pipWindow.focus();
      return;
    }

    const modal = document.querySelector(MODAL_SELECTOR);
    if (!modal) {
      console.warn('[NinjaPopout] Terminal modal not found.');
      return;
    }

    // Remember where to put it back, and preserve any existing inline styles
    // so we can restore them exactly — don't want to lose Ninja's own.
    restoreAnchor = {
      parent: modal.parentNode,
      nextSibling: modal.nextSibling,
      originalInlineStyle: modal.getAttribute('style') || ''
    };

    try {
      pipWindow = await documentPictureInPicture.requestWindow({
        width: 1000,
        height: 700
      });
    } catch (err) {
      console.error('[NinjaPopout] Failed to open PiP window:', err);
      restoreAnchor = null;
      return;
    }

    copyStyles(pipWindow.document);

    // Inject scoped overrides INTO the PiP document only. This avoids
    // touching the modal's own inline style attribute, so restoration is
    // clean — no remnants left behind when we move it back.
    const overrideStyle = pipWindow.document.createElement('style');
    overrideStyle.textContent = `
      html, body {
        margin: 0;
        padding: 0;
        background: #1a1a1a;
        height: 100vh;
        overflow: hidden;
      }
      .maccommand-line-modal,
      .maccommand-line-modal .modal-content {
        position: static !important;
        width: 100% !important;
        height: 100% !important;
        max-width: none !important;
        max-height: none !important;
        margin: 0 !important;
        transform: none !important;
        inset: auto !important;
      }
      .maccommand-line-modal .terminal.xterm {
        width: 100% !important;
        height: auto !important;
        flex: 1 1 auto !important;
      }
    `;
    pipWindow.document.head.appendChild(overrideStyle);

    // Tag the modal so we know it's currently popped out (for click interception).
    modal.dataset.ninjaPoppedOut = 'true';

    pipWindow.document.body.appendChild(modal);

    // Poke xterm to resize to the new container.
    const fireResize = () => {
      window.dispatchEvent(new Event('resize'));
      if (pipWindow) pipWindow.dispatchEvent(new Event('resize'));
    };
    fireResize();
    setTimeout(fireResize, 50);
    setTimeout(fireResize, 250);

    // Resize xterm as the user resizes the PiP window.
    pipWindow.addEventListener('resize', fireResize);

    // Intercept clicks on Ninja's terminate-session button while popped out.
    // If clicked, restore the modal to the main page FIRST, then forward the
    // click so Ninja's React handler runs against the correctly-parented DOM.
    modal.addEventListener('click', onInPipClick, true);

    pipWindow.addEventListener('pagehide', () => {
      restoreModal();
    }, { once: true });
  }

  function onInPipClick(e) {
    const terminateBtn = e.target.closest('button[aria-label="Terminate session"]');
    if (!terminateBtn) return;

    // Stop the current click; we'll re-issue it after restoring.
    e.preventDefault();
    e.stopPropagation();
    e.stopImmediatePropagation();

    const btnSelector = 'button[aria-label="Terminate session"]';
    // Close the PiP window — this triggers restoreModal() via the pagehide handler.
    if (pipWindow && !pipWindow.closed) {
      pipWindow.close();
    }

    // After restore (next tick), find the terminate button back in the main
    // page and click it. React's handler will fire in the correct context.
    setTimeout(() => {
      const btn = document.querySelector(btnSelector);
      if (btn) btn.click();
    }, 50);
  }

  function restoreModal() {
    const modal = document.querySelector(MODAL_SELECTOR) ||
                  (pipWindow && pipWindow.document && pipWindow.document.querySelector(MODAL_SELECTOR));

    if (modal && restoreAnchor && restoreAnchor.parent) {
      delete modal.dataset.ninjaPoppedOut;

      // Restore the EXACT original inline style attribute.
      // We didn't modify inline styles (we used scoped CSS in the PiP doc),
      // but reset the attribute anyway for safety.
      if (restoreAnchor.originalInlineStyle) {
        modal.setAttribute('style', restoreAnchor.originalInlineStyle);
      } else {
        modal.removeAttribute('style');
      }

      modal.removeEventListener('click', onInPipClick, true);

      try {
        restoreAnchor.parent.insertBefore(modal, restoreAnchor.nextSibling);
      } catch (err) {
        // Fallback: append to body if the original parent is gone.
        document.body.appendChild(modal);
      }
      window.dispatchEvent(new Event('resize'));
    }

    pipWindow = null;
    restoreAnchor = null;
  }

  // Watch for the terminal modal appearing/disappearing.
  // Ninja's React app mounts and unmounts it on demand, and the header
  // buttons may hydrate a tick after the modal itself appears.
  let retryTimer = null;
  function scheduleInjection() {
    injectButton();
    if (document.querySelector('#' + BUTTON_ID)) return;

    // Keep retrying for a few seconds in case buttons hydrate late.
    if (retryTimer) return;
    let attempts = 0;
    retryTimer = setInterval(() => {
      attempts++;
      injectButton();
      if (document.querySelector('#' + BUTTON_ID) || attempts > 40) {
        clearInterval(retryTimer);
        retryTimer = null;
      }
    }, 100); // 100ms * 40 = 4s total window
  }

  const observer = new MutationObserver(() => {
    scheduleInjection();
  });

  observer.observe(document.body, {
    childList: true,
    subtree: true
  });

  // Initial pass in case the modal is already open.
  scheduleInjection();
})();
