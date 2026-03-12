# Ghost workflow tests (no emulator)

Run the full workflow test suite **without an emulator or device**:

```bash
# From repo root
cd client
flutter test test/workflow/
```

Or run all tests (unit, widget, workflow) that don't require a device:

```bash
cd client
flutter test test/workflow/ test/core/ test/relay/ test/features/ test/models/
```

To run **every** test (including widget tests; still no emulator):

```bash
cd client
flutter test
```

## What the workflow tests cover

| Test | What it verifies |
|------|-------------------|
| Contact add flow | Create contact → `toDbMap` → `fromDbMap` → same data, displayName, shortId |
| Establishment message | Constant text and relay packet shape (id, to, ciphertext, msg_type, ttl_seconds) |
| Relay coordinator | Buffer and setCurrentChat (recipient side) |
| Message model | Round-trip toDbMap / fromDbMap for chat |
| Ghost ID share | Payload shape `ghost://add/userId/publicKeyB64` |
| ContactEstablishmentService | Singleton |

These tests use **no network**, **no Supabase**, and **no secure storage**; they only check data flow and contracts so you can validate the workflow before installing on a phone.
