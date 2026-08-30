# AI Safe Route Finder — Flutter Prototype (SIH)

Frontend-only prototype implementing the full flow from the team's
"HOW OUR APP WORKS" diagram, using mock/simulated data (no backend or
real map SDK required) so it's fast to demo to mentors.

## Screens included (mapped to the flowchart)

| # | Flowchart step | File |
|---|---|---|
| 1 | User Starts | `lib/screens/splash_screen.dart` |
| 2 | Sign In / Sign Up | `lib/screens/auth_screen.dart` |
| 3 | Enter Destination | `lib/screens/destination_screen.dart` |
| 4 | Safety Data Collection | `lib/screens/safety_collection_screen.dart` |
| 5 | AI Safety Analysis | `lib/screens/ai_analysis_screen.dart` |
| 5b | Is Route Safe Enough? / Alternative Route | `lib/screens/route_check_screen.dart` |
| 6+7 | Start Safe Navigation + Real-Time Monitoring | `lib/screens/navigation_screen.dart` |
| 8–10 | Auto SOS → Alert Sent → Help On The Way | `lib/screens/sos_screen.dart` |
| 11 | Journey Ends | `lib/screens/journey_end_screen.dart` |
| 12 | Post-Trip Feedback | `lib/screens/feedback_screen.dart` |
| 13 | Update Safety Database | `lib/screens/database_update_screen.dart` |

## How to run

1. Install the Flutter SDK: https://docs.flutter.dev/get-started/install
2. Unzip this project, then from inside the folder run:
   ```
   flutter pub get
   flutter run
   ```
   Pick any connected device / emulator / Chrome when prompted
   (`flutter run -d chrome` is the fastest way to demo on a laptop).

## Demo script for mentors

1. Splash → **Get Started** → fill any name/phone → **Create Account & Continue**
2. Pick a destination chip → **Find Safe Route**
3. Watch the 6 safety-data sources load (Step 4)
4. AI "calculates" a safety score (Step 5)
5. If score < 70%, tap **Generate Safer Alternative Route** to show the
   re-routing loop from the diagram; otherwise it goes straight through
6. On the navigation screen you'll see the live map, safety metrics
   (Safety Score, Crowd/Lighting Confidence, Help Availability, Data
   Confidence) and a pulsing "LIVE" monitoring indicator
7. Tap **Simulate Danger** to trigger the Auto-SOS timeline (Steps 8–10),
   then **I'm Safe — Recalculate Route & Continue** to show the loop
   back into monitoring
8. Tap **I Arrived** → journey-complete screen → star rating → database
   "updated" confirmation → **Start New Journey** loops back to Step 3

## Notes for the team

- All "AI" scoring, safety data, and map are **mocked** (`AppState` in
  `lib/state/app_state.dart` + `Random()` in `ai_analysis_screen.dart`)
  — swap in real APIs/ML model output later without touching the UI.
- The map is a custom-painted placeholder (`lib/widgets/route_map_painter.dart`)
  so the app runs with zero API keys; drop in `google_maps_flutter` later.
- Colors/branding in `lib/theme/app_theme.dart` match the flowchart's
  purple/blue/green/red/orange palette — tweak there to re-theme the
  whole app in one place.
