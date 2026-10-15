# SafeNav Guardian Backend

FastAPI backend powering the **SafeNav Guardian AI Agent**, **SafeRoutes IEEE DBSCAN Hotspot Clustering**, and **Real-Time Watchdog Monitoring**.

---

### Features
1. **AI Guardian Agent**:
   - Built with Google Gemini API (server-side, secret key never in the mobile app).
   - Guardrails: neutral framing, risk transparency, user consent before alerting, no PII leakage.
2. **SafeRoutes IEEE Paper Implementation**:
   - DBSCAN spatial clustering and grid-based density analysis for community safety reports.
3. **Trip Watchdog & Emergency Dispatcher**:
   - Analyzes off-route deviations, prolonged stops, vehicle departures, and missed check-ins.
   - Evaluates whether to prompt the user or escalate to emergency SOS.

---

### How to Run Locally

In PowerShell, open this `backend` directory:

```powershell
cd c:\dev\SafeNav\backend

# 1. Create a virtual environment
python -m venv .venv
.\.venv\Scripts\Activate.ps1

# 2. Install dependencies
pip install -r requirements.txt

# 3. (Optional) Set your Gemini API key from https://aistudio.google.com
$env:GEMINI_API_KEY = "your-gemini-key-here"
$env:AGENT_KEY = "safenav-secret"

# 4. Start the server
uvicorn server:app --reload --host 0.0.0.0 --port 8000
```

Once running:
- Interactive API Docs: `http://localhost:8000/docs`
- Health check: `http://localhost:8000/health`

### Connecting the Android Emulator
Run your Flutter app with:
```powershell
flutter run --dart-define=AGENT_URL=http://10.0.2.2:8000 --dart-define=AGENT_KEY=safenav-secret
```
*(On an Android emulator, `10.0.2.2` automatically points to `localhost` on your PC).*
