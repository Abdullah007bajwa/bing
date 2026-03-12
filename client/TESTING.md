# Testing Ghost (no emulator required)

You can test the whole workflow **before installing on a mobile device**.

## 1. Run all tests without emulator

From the `client` directory:

```bash
flutter test test/workflow/ test/core/ test/relay/ test/features/ test/models/
```

This runs:

- **Workflow tests** (`test/workflow/`) – contact add, establishment message, relay buffer, message model, Ghost ID shape
- **Core tests** – contact establishment service, ephemeral cache, onion router
- **Relay tests** – coordinator buffer and current-chat API
- **Feature tests** – ContactConfirmScreen, GhostIdScreen, ContactsScreen add sheet
- **Model tests** – message (if any)

No emulator or device is needed.

## 2. Run only the full workflow suite

```bash
flutter test test/workflow/
```

## 3. Optional: run the app on Chrome (manual click-through)

To click through the app in a browser (still no phone/emulator):

```bash
# Load env first; create .env from .env.example if needed
flutter run -d chrome
```

Not all features work on web (e.g. secure storage, some plugins). Use this for UI/navigation checks; use the test suite above for workflow logic.

## 4. Run tests before installing on mobile

Recommended before `flutter run` or building an APK:

```bash
cd client
flutter test test/workflow/ test/core/ test/relay/ test/features/
```

If all pass, the add-contact → establishment message → recipient-sees-contact flow is validated in code.

## 5. Relay and security (after installing on device)

1. **WebSocket**: Ensure `.env` has `RELAY_WSS_URL=wss://bing-2iqr.onrender.com/ws` (or your relay). The client appends `?uid=<ghost_id>` automatically. In debug builds you’ll see `[GhostRelay] Connecting to ...` in the console.
2. **Connection status**: In a chat, the status should show "Encrypted" when connected and "Reconnecting…" only when the connection is actually down.
3. **Screenshots**: Screenshot blocking is always on (no toggle). Try taking a screenshot; the app content should not appear.
4. **Biometric lock**: In Settings → Biometric Lock, turn it on. Restart the app or send it to background and resume; the unlock screen should appear and require fingerprint/face/PIN.
