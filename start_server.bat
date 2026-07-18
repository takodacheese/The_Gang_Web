@echo off
cd /d "%~dp0"
set PORT=8977
echo ==============================================
echo   The Gang - game server
echo   On this laptop:  http://localhost:8977
echo   Other devices on your WiFi use this laptop's
echo   IPv4 address below, e.g. http://192.168.x.x:8977
echo ==============================================
ipconfig | findstr /i "IPv4"
echo.
echo Close this window (or press Ctrl+C) to stop the server.
echo.
dart run relay/relay_server.dart
pause
