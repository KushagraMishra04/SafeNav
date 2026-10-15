# SafeNav — AI Safe Route Finder

SafeNav is an AI-powered safe route finder for **EVERYONE**: solo travellers, women, night-shift workers, students, elderly people, tourists, and delivery riders. Normal navigation apps prioritize the fastest route; SafeNav prioritizes the **safest** one, warns about isolated stretches in advance, and keeps trusted contacts informed in real-time.

SafeNav directly advances the UN Sustainable Development Goals:
- **SDG 11**: Sustainable & Safe Cities
- **SDG 5**: Gender Equality & Freedom of Movement
- **SDG 3**: Good Health, Security & Well-being

---

## 🌟 Key Features

1. **Safety-Weighted Routing & Risk-Stretch Warnings**:
   - Transparent scoring combining Street Lighting (30%), Crowd Footfall (25%), Proximity to Safe Havens (20%), and Community Reports (25%).
   - The route is split into ~150 m stretches. Weak segments are flagged as **"isolated stretches"** (never alarmist "danger").
2. **SafeNav Guardian AI Companion**:
   - Real-time conversational assistant powered by Google Gemini (server-side, secret key never in the mobile app).
   - Explains route trade-offs in plain language, answers questions (*"Is this area safe at 11 PM?"*), and guides to nearest safe havens (*"Take me somewhere safe now"*).
   - Trip Watchdog: detects unusual prolonged stops, off-route deviations, or vehicle departures. Prompts the user with a check-in before escalating to contacts.
3. **Emergency Response & Shake-to-SOS**:
   - Shake the phone 4 times or hold the SOS button for 5 seconds to activate the SOS timeline.
   - Guardian Timer: asks for confirmation before timer expires; alerts contacts if no response.
   - Logs events to the Firestore `sos_events` audit collection.
4. **Live Trip Sharing Web Tracker**:
   - Contacts can follow the user's progress on any web browser via `web_tracker/track.html`.
   - Displays real-time location, ETA, and emergency status with a 12-hour privacy TTL auto-expiry.
5. **SafeRoutes IEEE Paper Clustering**:
   - DBSCAN spatial clustering and density analysis on community safety reports to detect hotspots and calculate area safety metrics.
6. **Hackathon Demo Mode**:
   - Safe simulation of all SOS and check-in workflows on stage without real phone calls or SMS charges.

---

## 📁 Project Structure

```text
SafeNav/
├── android/                         # Android native config (permissions, google-services.json)
├── backend/                         # SafeNav Guardian Backend (FastAPI, Gemini API, DBSCAN)
│   ├── server.py                    # AI agent tools, watchdog, clustering endpoints
│   ├── requirements.txt             # Python dependencies
│   └── README.md                    # Backend run instructions
├── firestore.rules                  # Production security rules with expiring token policy
├── lib/
│   ├── firebase_options.dart        # Auto-generated FlutterFire configuration
│   ├── main.dart                    # App initialization & navigation routes
│   ├── screens/
│   │   ├── auth_screen.dart         # Email/Password + Google Sign-In + Guest Mode
│   │   ├── guardian_chat_screen.dart# SafeNav Guardian Conversational AI Assistant
│   │   ├── route_map_screen.dart    # Live OpenStreetMap, navigation, Guardian banner
│   │   └── ...                      # Flowchart demo screens
│   ├── services/
│   │   ├── agent_client.dart        # Client for Guardian AI with on-device fallback
│   │   ├── auth_service.dart        # Firebase Auth manager with GDPR account deletion
│   │   ├── firestore_service.dart   # Typed CRUD for Firestore collections
│   │   ├── safety_engine.dart       # OSM, Overpass & Photon routing engine
│   │   ├── stretch_engine.dart      # 150m segment scoring & risk evaluation
│   │   └── trip_share.dart          # Live tracking publisher with secure tokens
│   └── theme/                       # Design tokens & color system
├── web_tracker/                     # Live Web Tracker for trusted contacts
│   ├── index.html                   # Redirect to track.html
│   └── track.html                   # Leaflet live tracking page reading Firestore
├── firebase.json                    # Firebase deployment config for rules & hosting
└── SETUP_GUIDE.md                   # Complete beginner setup and hackathon presentation guide
```

---

## 🚀 Quick Start

### 1. Run Flutter App
```powershell
flutter pub get
flutter run
```

### 2. Run Backend (Optional for Cloud AI)
```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
uvicorn server:app --reload --host 0.0.0.0 --port 8000
```

### 3. Deploy Firestore Rules & Web Tracker
```powershell
firebase deploy --only firestore:rules,hosting
```

---

*For full instructions, architecture diagrams, and hackathon presentation scripts, see [SETUP_GUIDE.md](SETUP_GUIDE.md).*
