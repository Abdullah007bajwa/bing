# Vexa Play Store Release Checklist

## 1) Accounts and project setup
- [ ] Google Play Console account created and app entry added.
- [ ] Firebase project linked to Android/iOS app IDs.
- [ ] FCM enabled and `google-services.json` / `GoogleService-Info.plist` downloaded.

## 2) IDs and branding
- [x] Android package ID set to `com.vexa.app`.
- [x] iOS bundle ID set to `com.vexa.app`.
- [x] App name updated to `Vexa` on launcher/shell.
- [x] Launcher icons generated from `../icon.png`.
- [x] Native splash generated from `../icon.png`.

## 3) Android signing (required for production)
- [ ] Generate upload keystore:
  - `keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload`
- [ ] Create `android/key.properties` from `android/key.properties.example`.
- [ ] Fill real values:
  - `storePassword`
  - `keyPassword`
  - `keyAlias`
  - `storeFile=../upload-keystore.jks`
- [x] `android/app/build.gradle` reads `key.properties` and uses `signingConfigs.release` when present.

## 4) Push notifications (FCM)
- [ ] Place `android/app/google-services.json`.
- [ ] Place `ios/Runner/GoogleService-Info.plist`.
- [ ] Set relay env var: `FCM_SERVER_KEY`.
- [ ] Verify token registration endpoint `/register_device` is reachable from app.
- [ ] Test foreground, background, and terminated notification flows.

## 5) App content and policy
- [ ] Privacy Policy URL hosted and added to Play listing.
- [ ] Data safety form completed (encryption + stored identifiers).
- [ ] Content rating questionnaire completed.
- [ ] App access instructions added if needed.
- [ ] Target audience and ads declarations completed.

## 6) Build and upload
- [ ] Build release AAB: `flutter build appbundle --release`.
- [ ] Upload AAB to Internal testing track.
- [ ] Verify install/update on multiple devices.
- [ ] Validate push, offline delivery, chat ordering, and disappearing timer behavior.
- [ ] Promote to Closed/Open/Production after validation.

## 7) Pre-launch QA must-pass
- [ ] New incoming message moves chat to top instantly.
- [ ] Custom timer values apply per chat (`off`, `5m`, `1h`, `24h`, custom).
- [ ] Offline recipient gets message after reconnect.
- [ ] Foreground shows in-app banner; background/terminated shows OS push.
- [ ] Double-tick status (`sent`, `delivered`, `read`) visible and accurate.
