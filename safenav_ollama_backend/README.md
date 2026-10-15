# SafeNav local Ollama backend (Windows development)

This replaces the Anthropic API version of `agent.py` with a local Ollama model. No Anthropic API key or paid AI credits are needed. It is intended for local development; a cloud-hosted backend cannot normally access Ollama running on your personal PC.

## 1. Install Ollama and model
1. Install Ollama from https://ollama.com/download/windows
2. Open PowerShell and run: `ollama run llama3.2:3b`
3. Wait for the download; when the model prompt appears, type `/bye` to exit. Ollama normally remains running in the background.

## 2. Set up backend
Open PowerShell in this folder (the folder containing `agent.py`) and run:

```powershell
py -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install -r requirements.txt
$env:APP_KEY = "safenav-local-dev-key-change-this"
$env:MODEL = "llama3.2:3b"
python agent.py
```

If PowerShell blocks activation, use `Set-ExecutionPolicy -Scope Process Bypass` in that terminal, then activate again. Or use `\.venv\Scripts\python.exe -m pip install -r requirements.txt` and `\.venv\Scripts\python.exe agent.py` without activation.

## 3. Check backend
Open `http://127.0.0.1:8080/health` in your PC browser. It should show `ok: true`.

In a second PowerShell terminal, from this folder, test the advice endpoint:

```powershell
$body = Get-Content .\test_request.json -Raw
Invoke-RestMethod -Uri http://127.0.0.1:8080/agent/advise -Method Post -Headers @{"X-App-Key"="safenav-local-dev-key-change-this"} -ContentType "application/json" -Body $body
```

## 4. Connect Android emulator
With the backend still running, start the Flutter app from Android Studio's Terminal:

```powershell
flutter run --dart-define=AGENT_URL=http://10.0.2.2:8080 --dart-define=AGENT_KEY=safenav-local-dev-key-change-this
```

`10.0.2.2` is the Android emulator's special address for the host computer. For a physical phone, use your PC's local Wi-Fi IPv4 address instead and allow port 8080 through Windows Firewall only on a private network.

For local HTTP development, Android may need cleartext HTTP enabled in `android/app/src/main/AndroidManifest.xml` on the `<application>` element: `android:usesCleartextTraffic="true"`. Use HTTPS and proper secrets for production.

## Security notes
- Do not commit real secrets to Git or put the Anthropic key in Flutter. This local development example uses a placeholder app key.
- A key embedded in a Flutter app can be extracted; it is only a basic local testing guard, not production authentication.
- Ollama uses your PC's CPU/GPU/RAM. With 16 GB RAM, `llama3.2:3b` is a reasonable small starting model.
