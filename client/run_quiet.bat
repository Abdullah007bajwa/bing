@echo off
REM Run app and show only Flutter tag (hides Android BufferQueueProducer / D/ E/ spam)
flutter run 2>&1 | findstr /i "flutter"
exit /b 0
