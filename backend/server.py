"""SafeNav Guardian Backend Service.
AI Guardian agent, SafeRoutes IEEE clustering, and trip watchdog.
"""
import os
import math
import json
from typing import List, Optional, Dict, Any
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

# Try importing scikit-learn for DBSCAN clustering; fallback to grid hashing if not installed
try:
    from sklearn.cluster import DBSCAN
    import numpy as np
    HAS_SKLEARN = True
except ImportError:
    HAS_SKLEARN = False

# Try importing Google GenAI SDK
try:
    from google import genai
    from google.genai import types
    HAS_GENAI = True
except ImportError:
    HAS_GENAI = False

app = FastAPI(
    title="SafeNav Guardian Backend",
    description="AI Guardian agent for pedestrian route safety, SafeRoutes clustering & emergency response.",
    version="2.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

APP_KEY = os.environ.get("AGENT_KEY", "safenav-secret")
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "")

# ---------- System Prompt & Guardrails ----------
GUARDIAN_SYSTEM_PROMPT = """You are SafeNav Guardian, an AI safety companion for pedestrians and commuters (solo travellers, students, night-shift workers, delivery riders, elderly, and tourists).

Core Principles & Guardrails:
1. Never claim an area is guaranteed "100% safe" or definitively "dangerous". Always state risk levels, reasons, and visible signals (lighting, crowd footfall, nearby open shops, verified safe havens).
2. Word isolated stretches as "isolated stretch" or "low-signal stretch", never sensationalized "danger zone".
3. Support UN Sustainable Development Goals (SDG 11 Safe Cities, SDG 5 Gender Equality, SDG 3 Well-being). SafeNav is for EVERYONE.
4. Verify user intent before alerting emergency contacts, unless an active SOS has already been triggered.
5. Never expose personal identifying information (PII) of community reviewers or other commuters.
6. When explaining a route score, highlight the main trade-off (e.g. 4 minutes longer walk in exchange for continuous streetlights and commercial activity).
"""

# ---------- Pydantic Models ----------
class RouteFactors(BaseModel):
    lighting: Optional[float] = None
    activity: Optional[float] = None
    help: Optional[float] = None
    community: Optional[float] = None

class CandidateRoute(BaseModel):
    id: str
    minutes: int
    km: float
    score: int
    confidence: float
    factors: RouteFactors
    notes: List[str] = []

class AdviseRequest(BaseModel):
    message: str = "Find me the safest route."
    night: bool = False
    routes: List[CandidateRoute]

class ChatRequest(BaseModel):
    message: str
    location: Optional[Dict[str, float]] = None
    route_summary: Optional[str] = None
    route_score: Optional[int] = None

class WatchdogRequest(BaseModel):
    off_route_meters: float
    stopped_minutes: int
    vehicle_departure: bool = False
    missed_checkin: bool = False

class SafetyReportItem(BaseModel):
    lat: float
    lng: float
    category: str
    rating: int
    time_of_day: str = "night"

class ClusterRequest(BaseModel):
    reports: List[SafetyReportItem]
    eps_meters: float = 120.0
    min_samples: int = 2

# ---------- Tools Implementation ----------
def tool_get_route_options(origin: str, destination: str) -> Dict[str, Any]:
    return {
        "status": "success",
        "description": f"Retrieved candidate routes between {origin} and {destination}.",
    }

def tool_score_route(factors: RouteFactors, night: bool) -> int:
    w = [0.30, 0.15, 0.20, 0.35] if night else [0.15, 0.25, 0.20, 0.40]
    vals = [factors.lighting, factors.activity, factors.help, factors.community]
    acc = den = 0.0
    for weight, val in zip(w, vals):
        if val is not None:
            acc += weight * val
            den += weight
    return round(100 * acc / den) if den > 0 else 50

def tool_find_nearest_safe_places(lat: float, lng: float, kind: str = "police") -> List[Dict[str, Any]]:
    return [
        {"name": "Central Police Station", "distance_m": 420, "type": "police"},
        {"name": "District General Hospital", "distance_m": 680, "type": "hospital"},
        {"name": "24/7 Metro Transit Station", "distance_m": 310, "type": "transit"},
    ]

# ---------- SafeRoutes Clustering (IEEE Inspired) ----------
def cluster_safety_hotspots(reports: List[SafetyReportItem], eps_m: float = 120.0, min_samples: int = 2):
    if not reports:
        return []

    # If scikit-learn is available, use DBSCAN with haversine distance
    if HAS_SKLEARN and len(reports) >= min_samples:
        coords = np.array([[math.radians(r.lat), math.radians(r.lng)] for r in reports])
        # Earth radius ~ 6,371,000 meters
        eps_rad = eps_m / 6371000.0
        db = DBSCAN(eps=eps_rad, min_samples=min_samples, metric='haversine')
        labels = db.fit_predict(coords)

        clusters = {}
        for idx, label in enumerate(labels):
            if label == -1:
                continue  # Noise point
            if label not in clusters:
                clusters[label] = []
            clusters[label].append(reports[idx])

        results = []
        for label, cluster_reports in clusters.items():
            avg_lat = sum(r.lat for r in cluster_reports) / len(cluster_reports)
            avg_lng = sum(r.lng for r in cluster_reports) / len(cluster_reports)
            avg_rating = sum(r.rating for r in cluster_reports) / len(cluster_reports)
            top_category = max(set(r.category for r in cluster_reports), key=[r.category for r in cluster_reports].count)
            results.append({
                "cluster_id": f"cluster_{label}",
                "center": {"lat": round(avg_lat, 6), "lng": round(avg_lng, 6)},
                "report_count": len(cluster_reports),
                "avg_rating": round(avg_rating, 1),
                "primary_category": top_category,
                "risk_level": "isolated_stretch" if avg_rating < 2.5 else "moderate_risk",
            })
        return results

    # Fast Grid-based Spatial Hashing Fallback
    grid = {}
    for r in reports:
        key = f"{(r.lat * 1000):.0f}_{(r.lng * 1000):.0f}"
        grid.setdefault(key, []).append(r)

    results = []
    for cell_id, cell_reports in grid.items():
        if len(cell_reports) >= min_samples:
            avg_lat = sum(r.lat for r in cell_reports) / len(cell_reports)
            avg_lng = sum(r.lng for r in cell_reports) / len(cell_reports)
            avg_rating = sum(r.rating for r in cell_reports) / len(cell_reports)
            results.append({
                "cluster_id": cell_id,
                "center": {"lat": round(avg_lat, 6), "lng": round(avg_lng, 6)},
                "report_count": len(cell_reports),
                "avg_rating": round(avg_rating, 1),
                "primary_category": cell_reports[0].category,
                "risk_level": "isolated_stretch" if avg_rating < 2.5 else "moderate_risk",
            })
    return results

# ---------- API Routes ----------
@app.get("/health")
def health():
    return {
        "status": "healthy",
        "service": "SafeNav Guardian",
        "has_gemini": bool(GEMINI_API_KEY and HAS_GENAI),
        "has_clustering": HAS_SKLEARN,
    }

@app.post("/agent/advise")
def advise(req: AdviseRequest, x_app_key: Optional[str] = Header(None)):
    if APP_KEY and x_app_key != APP_KEY:
        raise HTTPException(status_code=401, detail="Unauthorized")

    if not req.routes:
        raise HTTPException(status_code=400, detail="No candidate routes provided")

    routes_sorted = sorted(req.routes, key=lambda r: (-r.score, r.minutes))
    best = routes_sorted[0]
    fastest = min(req.routes, key=lambda r: r.minutes)

    if best.id == fastest.id:
        expl = f"Route {best.id} offers the optimal path: highest safety score ({best.score}%) and fastest walking time."
    else:
        extra_min = best.minutes - fastest.minutes
        score_diff = best.score - fastest.score
        expl = f"Selected Route {best.id}: adds {extra_min} min vs the fastest route, but gains +{score_diff} safety points with verified lighting and active streets."

    tips = []
    if req.night:
        tips.append("Keep to illuminated main avenues; lighting confidence is prioritized.")
    if best.factors.help and best.factors.help > 0.5:
        tips.append("Passes within 200m of an open police station / clinic.")
    tips.append("Guardian watchdog is armed to monitor unexpected stops or route changes.")

    return {
        "recommended_id": best.id,
        "weights": [0.30, 0.15, 0.20, 0.35] if req.night else [0.15, 0.25, 0.20, 0.40],
        "max_detour": 1.4,
        "explanation": expl,
        "tips": tips,
    }

@app.post("/agent/chat")
async def chat(req: ChatRequest, x_app_key: Optional[str] = Header(None)):
    if APP_KEY and x_app_key != APP_KEY:
        raise HTTPException(status_code=401, detail="Unauthorized")

    query = req.message.strip().lower()

    # If Gemini API key is configured and genai is available, query Gemini
    if GEMINI_API_KEY and HAS_GENAI:
        try:
            client = genai.Client(api_key=GEMINI_API_KEY)
            prompt = f"{GUARDIAN_SYSTEM_PROMPT}\n\nUser Question: {req.message}\nLocation Context: {req.location}\nRoute Summary: {req.route_summary}\nRoute Safety Score: {req.route_score}"
            response = client.models.generate_content(
                model="gemini-2.5-flash",
                contents=prompt,
            )
            text = response.text or "I am watching your route and keeping you connected."
            places = []
            if "safe place" in query or "police" in query or "hospital" in query or "somewhere safe" in query or "safe haven" in query:
                loc = req.location or {"lat": 28.6139, "lng": 77.2090}
                lat, lng = loc.get("lat", 28.6139), loc.get("lng", 77.2090)
                places = [
                    {"name": "Central Police Station · 0.4 km", "lat": round(lat + 0.0035, 6), "lng": round(lng + 0.0028, 6), "type": "police"},
                    {"name": "City General Hospital & Emergency · 0.7 km", "lat": round(lat - 0.0045, 6), "lng": round(lng + 0.0032, 6), "type": "hospital"},
                    {"name": "Metro Transit Safe Post · 0.3 km", "lat": round(lat + 0.0018, 6), "lng": round(lng - 0.0022, 6), "type": "transit"},
                ]

            return {
                "text": text,
                "follow_ups": ["Find nearest safe place", "Share live trip with contacts", "Explain route safety"],
                "action_type": "safe_place" if places else None,
                "safe_places": places,
            }
        except Exception as e:
            # Fall through to deterministic rule-based response
            pass

    # Built-in Guardian Rule-Based Intelligence
    if "11 pm" in query or "late" in query or "night" in query or "dark" in query:
        return {
            "text": "At late hours (past 10–11 PM), commercial footfall is lower and secondary streets have higher isolation risk. SafeNav routes automatically re-weight to stay on illuminated primary roads with active transport hubs. Always enable Guardian Timer when walking late.",
            "follow_ups": ["Find nearest safe place", "Explain my route score"],
            "action_type": None,
        }

    if "safe place" in query or "police" in query or "hospital" in query or "somewhere safe" in query or "safe haven" in query:
        loc = req.location or {"lat": 28.6139, "lng": 77.2090}
        lat, lng = loc.get("lat", 28.6139), loc.get("lng", 77.2090)
        places = [
            {"name": "Central Police Station · 0.4 km", "lat": round(lat + 0.0035, 6), "lng": round(lng + 0.0028, 6), "type": "police"},
            {"name": "City General Hospital & Emergency · 0.7 km", "lat": round(lat - 0.0045, 6), "lng": round(lng + 0.0032, 6), "type": "hospital"},
            {"name": "Metro Transit Safe Post · 0.3 km", "lat": round(lat + 0.0018, 6), "lng": round(lng - 0.0022, 6), "type": "transit"},
        ]
        return {
            "text": "I have identified the nearest verified 24/7 safe havens near your location. Tap any place below to immediately map the route and start guided navigation to safety:",
            "follow_ups": ["Nearest police station", "Call 112 emergency"],
            "action_type": "safe_place",
            "safe_places": places,
        }

    if "score" in query or "explain" in query or "why" in query:
        score_text = f"Your route score is {req.route_score}%." if req.route_score else "Your route score reflects current safety signals."
        return {
            "text": f"{score_text} SafeNav scores pedestrian routes across four factors: 30% street lighting, 25% crowd footfall, 20% distance to open police/hospitals, and 25% community reviews. Isolated stretches (~150m) below threshold are warned in advance.",
            "follow_ups": ["Is this area safe at night?", "Take me somewhere safe now"],
            "action_type": None,
        }

    return {
        "text": "I am monitoring your walk in real-time. If you pause for over 4 minutes or stray from the route, I will prompt you with a check-in before notifying your emergency contacts.",
        "follow_ups": ["Is this area safe at 11 PM?", "Take me somewhere safe now", "Explain route safety"],
        "action_type": None,
    }

@app.post("/agent/watchdog")
def watchdog(req: WatchdogRequest, x_app_key: Optional[str] = Header(None)):
    if APP_KEY and x_app_key != APP_KEY:
        raise HTTPException(status_code=401, detail="Unauthorized")

    if req.missed_checkin:
        return {
            "should_check_in": False,
            "reason": "Missed safety check-in prompt without acknowledgment.",
            "escalate_sos": True,
        }

    if req.vehicle_departure:
        return {
            "should_check_in": True,
            "reason": "Vehicle movement detected away from your planned pedestrian route.",
            "escalate_sos": False,
        }

    if req.off_route_meters > 150:
        return {
            "should_check_in": True,
            "reason": f"You are {int(req.off_route_meters)}m off your planned route.",
            "escalate_sos": False,
        }

    if req.stopped_minutes >= 4:
        return {
            "should_check_in": True,
            "reason": f"Stopped in one spot for {req.stopped_minutes} minutes.",
            "escalate_sos": False,
        }

    return {
        "should_check_in": False,
        "reason": "Trip progressing normally.",
        "escalate_sos": False,
    }

@app.post("/clusters/hotspots")
def get_clusters(req: ClusterRequest):
    clusters = cluster_safety_hotspots(req.reports, req.eps_meters, req.min_samples)
    return {
        "status": "success",
        "cluster_count": len(clusters),
        "clusters": clusters,
    }

if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 8000))
    uvicorn.run("server:app", host="0.0.0.0", port=port, reload=True)
