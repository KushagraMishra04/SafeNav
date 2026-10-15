# SafeNav — Setup & Hackathon Demo Guide

SafeNav is an AI-powered safe route finder for **everyone** (solo travellers, night-shift workers, students, delivery riders, elderly, and tourists). Based on the IEEE paper *"SafeRoutes: Charting a Secure Path"*, it optimizes for safety over pure speed, provides advance warnings for isolated stretches, and maintains a live guardian connection to trusted contacts.

---

## 🏛️ System Architecture

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                       SafeNav Flutter Mobile App (Android)                  │
│                                                                             │
│  [Live Map & Nav]  <──>  [Guardian AI Chat]  <──>  [Auth & SOS Watchdog]    │
│  (route_map_screen)       (guardian_chat_screen)     (auth_service.dart)    │
└─────────────┬────────────────────────┬──────────────────────┬───────────────┘
              │                        │                      │
              │ Real-time Sync         │ User Auth            │ REST / Tools
              ▼                        ▼                      ▼
┌───────────────────────────┐ ┌────────────────┐ ┌────────────────────────────┐
│    Firebase Firestore     │ │ Firebase Auth  │ │  SafeNav Guardian Backend  │
│                           │ │                │ │       (FastAPI / AI)       │
│ • users                   │ │ • Email/Pass   │ │                            │
│ • trusted_contacts        │ │ • Google       │ │ • Gemini 2.5 Flash LLM     │
│ • trips (12h TTL expiry)  │ │ • Guest Mode   │ │ • DBSCAN Hotspot Clustering│
│ • safety_reports          │ └────────────────┘ │ • Watchdog Decision Engine │
│ • sos_events              │                    │ • Safe Haven Geosearch     │
│ • areas (clusters)        │                    └──────────────┬─────────────┘
└─────────────┬─────────────┘                                   │
              │                                                 │
              ▼                                                 ▼
┌───────────────────────────┐                    ┌────────────────────────────┐
│    Firebase Hosting       │                    │   External Safety Data     │
│   (web_tracker/track.html)│                    │                            │
│ • Live map for contacts   │                    │ • OpenStreetMap / Overpass │
│ • Real-time status badge  │                    │ • OSRM Foot Routing        │
│ • Direct emergency call   │                    │ • Photon Geocoding         │
└───────────────────────────┘                    └────────────────────────────┘
```

---

## 🚀 1. Running the Flutter App

Your project is already configured with Firebase (`safenav-4b482`) and all dependencies are installed.

### Option A: Standard Run (Using Built-in On-Device Guardian)
```powershell
flutter run
```

### Option B: Run Connected to the AI Backend
```powershell
flutter run --dart-define=AGENT_URL=http://10.0.2.2:8000 --dart-define=AGENT_KEY=safenav-secret
```
*(On Android emulators, `10.0.2.2` automatically points to `localhost` on your computer).*

---

## 🤖 2. Running the AI Guardian Backend (Python)

Open a new PowerShell terminal and navigate to `backend`:

```powershell
cd c:\dev\SafeNav\backend

# 1. Create and activate a virtual environment
python -m venv .venv
.\.venv\Scripts\Activate.ps1

# 2. Install dependencies (FastAPI, scikit-learn for DBSCAN, Gemini SDK)
pip install -r requirements.txt

# 3. (Optional) Set your free Gemini API key from https://aistudio.google.com
$env:GEMINI_API_KEY = "YOUR_GEMINI_KEY"
$env:AGENT_KEY = "safenav-secret"

# 4. Start the server
uvicorn server:app --reload --host 0.0.0.0 --port 8000
```
- Interactive API Swagger Docs: `http://localhost:8000/docs`
- Health Check: `http://localhost:8000/health`

---

## ☁️ 3. Deploying Firestore Rules & Web Tracker to Firebase

To deploy your security rules and the Live Web Tracker so contacts can open it from anywhere:

```powershell
# In the root project folder:
firebase deploy --only firestore:rules,hosting
```

Once deployed, your live tracker web page will be available live at:
👉 **`https://safenav-4b482.web.app/track.html`**

---

## 🛡️ 4. Firebase Console Checklist (One-Time)

In [console.firebase.google.com](https://console.firebase.google.com) under project **SafeNav** (`safenav-4b482`):
1. **Authentication > Sign-in method**:
   - Enable **Email/Password**
   - Enable **Google**
   - Enable **Anonymous** (for Guest Mode)
2. **Firestore Database**:
   - Ensure Cloud Firestore is enabled (Location: `asia-south1` or default).

---

## 🎯 5. Hackathon Demo Script (How to wow the judges!)

SafeNav comes with a built-in **Hackathon Demo Mode** so you can safely simulate all emergencies on stage without spamming real emergency lines or charging your SIM:

### Step 1: Authentication & Guest Access
1. Launch the app.
2. Demonstrate **Google Sign-In**, **Email Signup**, or tap **Continue as guest** to bypass login instantly.

### Step 2: Route Planning & Transparent Scoring
1. On the map, type any destination (e.g., "Metro Station").
2. Show the route options with the **Safety Score %**.
3. Tap the **Guardian** button on the right side of the map to open the **AI Guardian Companion Chat**.
4. Tap the prompt chip: *"Explain my route safety score"*.
5. Show how the AI explains the trade-off (e.g. *"Adds 3 minutes vs the fastest route, but keeps you on active commercial streets with street lighting"*).

### Step 3: Isolated Stretch Warning (150 m)
1. Point out the route segments: SafeNav colors the route into ~150 m stretches (green, amber, red).
2. Show that SafeNav uses respectful wording: **"Isolated stretch"**, never alarmist "danger".

### Step 4: Live Trip Sharing
1. Tap **More Options > Share trip**.
2. Open the generated link on your laptop browser: `https://safenav-4b482.web.app/track.html?t=...`
3. Show the live map updating in real-time as the phone navigates!

### Step 5: Demo Emergency SOS Simulation
1. In **More Options**, ensure **Demo Mode (ON)** is active.
2. Shake the phone 4 times (or press and hold the red SOS button).
3. Watch the 5-second cancel countdown.
4. When it triggers, show:
   - The phone displays the simulated SOS alert dialog.
   - The web tracker on your laptop instantly turns **red** with a flashing **EMERGENCY SOS** banner!
   - The SOS event is permanently recorded in the Firestore `sos_events` audit collection.

### Step 6: Privacy Compliance
1. Tap the Profile icon (top bar) > show **Delete My Account & Data**.
2. Explain to judges how SafeNav adheres to GDPR and UN SDGs (SDG 11, SDG 5, SDG 3) by wiping live locations after 12 hours and allowing immediate data deletion.
