<img align="left" width="32" height="32" src="https://github.com/user-attachments/assets/20205c1d-1c8e-4132-a9bf-0bfdc09323bf"> 


# NinjaOne Terminal Popout

Adds a **popout button** to the NinjaOne terminal header...


Adds a **popout button** to the NinjaOne terminal header that moves the entire terminal modal into a Document Picture-in-Picture window. The PiP window is a real OS-level window, so you can drag it to another monitor.

<img width="323" height="344" alt="image" src="https://github.com/user-attachments/assets/1cad4339-0228-4e95-870c-957d75f0ceb3" />



## Install (unpacked)

1. Download the latest `ninja-terminal-popout.zip` from this repo.
2. Extract the zip. **Move the extracted folder to a permanent location** — not Downloads, not your Desktop. If you delete or move the folder later, the extension will break.
3. Go to `edge://extensions` (or `chrome://extensions`).
4. Toggle **Developer mode** on (top-right).
5. Click **Load unpacked**.
6. Select the `ninja-terminal-popout` folder you extracted in step 2.
7. Open a NinjaOne device page and click the terminal (`>_`) button.
8. You should see a small **popout icon** in the terminal header, to the left of the keyboard icon.
9. Click it. The terminal moves into a floating window you can drag anywhere.

## Usage

- Click the popout icon → terminal jumps into a floating window.
<img width="1093" height="654" alt="image" src="https://github.com/user-attachments/assets/373724ea-4d44-4e91-b244-ee2d3087bd90" />


- Drag the window to any monitor.
- Resize it as needed — xterm auto-fits.
- Close the floating window (X) → terminal snaps back to the main page.
<img width="922" height="679" alt="image" src="https://github.com/user-attachments/assets/7685c079-f101-42d9-9bd2-7fb14dbd36c1" />


- Then close the terminal the normal way (Ninja's X) to end the session cleanly.

## Scope

Runs only on `*.rmmservices.net`. Adjust the `matches` field in `manifest.json` if your Ninja instance is on a different domain.

## Requirements

- Chromium-based browser with Document PiP support (Chrome/Edge 116+).

## Notes

- The entire modal (header bar + terminal body) is moved together, so all the Ninja controls (keyboard, download, copy, close) come along.
- On close, the modal is restored to its exact original position in the DOM.
- The WebSocket connection is not affected by the reparent — xterm.js handles this cleanly.
