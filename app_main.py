"""
SmartDoor Facility API — Production Backend
FastAPI + JWT Auth + RBAC + WebSocket + Prometheus Metrics
"""
from fastapi import FastAPI, HTTPException, Depends, WebSocket, WebSocketDisconnect, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.responses import Response
from pydantic import BaseModel
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
from typing import Optional, List
import asyncio, json, logging, os, time, uuid, hashlib
from datetime import datetime, timedelta
import jwt

logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)s | %(message)s")
logger = logging.getLogger("smartdoor")

app = FastAPI(
    title="SmartDoor Facility API",
    description="Enterprise Smart Door Management — DevOps & FinOps integrated",
    version="2.0.0"
)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

# Prometheus Metrics
door_access_total   = Counter("door_access_total",   "Door access events",    ["door_id", "status"])
auth_attempts_total = Counter("auth_attempts_total", "Auth attempts",          ["result"])
api_latency         = Histogram("api_latency_seconds","API request latency",  ["endpoint"])
active_websockets   = Gauge("active_websockets_total","Live WS connections")
doors_online        = Gauge("doors_online_total",    "Doors currently online")

SECRET_KEY = os.getenv("JWT_SECRET_KEY", "smartdoor-change-in-prod")
ALGORITHM  = "HS256"
security   = HTTPBearer()

USERS_DB = {
    "admin":    {"hash": hashlib.sha256(b"admin123").hexdigest(),   "role": "admin",    "name": "Admin User"},
    "security": {"hash": hashlib.sha256(b"security123").hexdigest(),"role": "security", "name": "Security Officer"},
    "employee": {"hash": hashlib.sha256(b"emp123").hexdigest(),     "role": "employee", "name": "John Employee"},
}

DOORS_DB = {
    "DOOR-001": {"name": "Main Entrance",    "building": "HQ",    "floor": 1, "status": "locked",   "online": True},
    "DOOR-002": {"name": "Server Room",      "building": "HQ",    "floor": 2, "status": "locked",   "online": True},
    "DOOR-003": {"name": "Conference Hall A","building": "HQ",    "floor": 1, "status": "unlocked", "online": True},
    "DOOR-004": {"name": "Parking Gate",     "building": "Annex", "floor": 0, "status": "locked",   "online": False},
    "DOOR-005": {"name": "Emergency Exit",   "building": "HQ",    "floor": 2, "status": "locked",   "online": True},
}

ACCESS_LOGS: List[dict] = []
connected_ws: List[WebSocket] = []


class LoginRequest(BaseModel):
    username: str
    password: str

class DoorControlRequest(BaseModel):
    door_id: str
    action: str  # lock | unlock | status
    reason: Optional[str] = None


def create_token(data: dict) -> str:
    payload = {**data, "exp": datetime.utcnow() + timedelta(minutes=30)}
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)

def verify_token(creds: HTTPAuthorizationCredentials = Depends(security)):
    try:
        payload = jwt.decode(creds.credentials, SECRET_KEY, algorithms=[ALGORITHM])
        username = payload.get("sub")
        if not username or username not in USERS_DB:
            raise HTTPException(401, "Invalid token")
        return {"username": username, **USERS_DB[username]}
    except jwt.ExpiredSignatureError:
        raise HTTPException(401, "Token expired")
    except jwt.InvalidTokenError:
        raise HTTPException(401, "Invalid token")

async def broadcast(event: dict):
    dead = []
    for ws in connected_ws:
        try:    await ws.send_text(json.dumps(event))
        except: dead.append(ws)
    for ws in dead:
        connected_ws.remove(ws)


@app.on_event("startup")
async def startup():
    doors_online.set(sum(1 for d in DOORS_DB.values() if d["online"]))
    logger.info("SmartDoor API started")


@app.get("/",           tags=["Health"])
async def root():       return {"service": "SmartDoor API", "version": "2.0.0", "status": "operational"}

@app.get("/health",     tags=["Health"])
async def health():     return {"status": "healthy", "doors_online": sum(1 for d in DOORS_DB.values() if d["online"])}

@app.get("/metrics",    tags=["Observability"])
async def metrics():    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/auth/login", tags=["Auth"])
async def login(req: LoginRequest):
    user = USERS_DB.get(req.username)
    if not user or hashlib.sha256(req.password.encode()).hexdigest() != user["hash"]:
        auth_attempts_total.labels(result="failed").inc()
        raise HTTPException(401, "Invalid credentials")
    auth_attempts_total.labels(result="success").inc()
    token = create_token({"sub": req.username, "role": user["role"]})
    return {"access_token": token, "token_type": "bearer", "user": {"username": req.username, "role": user["role"]}}


@app.get("/doors",               tags=["Doors"])
async def list_doors(u=Depends(verify_token)):
    return {"doors": DOORS_DB, "total": len(DOORS_DB)}

@app.get("/doors/{door_id}",     tags=["Doors"])
async def get_door(door_id: str, u=Depends(verify_token)):
    if door_id not in DOORS_DB: raise HTTPException(404, f"Door {door_id} not found")
    return DOORS_DB[door_id]

@app.post("/doors/{door_id}/control", tags=["Doors"])
async def control_door(door_id: str, req: DoorControlRequest, bg: BackgroundTasks, u=Depends(verify_token)):
    t0 = time.time()
    if door_id not in DOORS_DB: raise HTTPException(404, "Door not found")
    if not DOORS_DB[door_id]["online"]: raise HTTPException(503, "Door offline")
    if req.action not in ["lock", "unlock", "status"]: raise HTTPException(400, "Invalid action")
    if req.action != "status" and u["role"] not in ["admin", "security"]:
        raise HTTPException(403, "Insufficient permissions")
    if req.action != "status":
        DOORS_DB[door_id]["status"] = "locked" if req.action == "lock" else "unlocked"
    door_access_total.labels(door_id=door_id, status="success").inc()
    log = {"id": str(uuid.uuid4()), "door_id": door_id, "user": u["username"],
           "action": req.action, "timestamp": datetime.utcnow().isoformat()}
    ACCESS_LOGS.append(log)
    bg.add_task(broadcast, {"type": "door_event", **log})
    api_latency.labels(endpoint="/doors/control").observe(time.time() - t0)
    return {"message": f"Door {door_id} {req.action}ed", "log": log}


@app.get("/access-logs",         tags=["Audit"])
async def access_logs(limit: int = 50, u=Depends(verify_token)):
    return {"logs": ACCESS_LOGS[-limit:], "total": len(ACCESS_LOGS)}

@app.get("/dashboard/stats",     tags=["Dashboard"])
async def dashboard_stats(u=Depends(verify_token)):
    total = len(DOORS_DB)
    locked = sum(1 for d in DOORS_DB.values() if d["status"] == "locked")
    online = sum(1 for d in DOORS_DB.values() if d["online"])
    today = datetime.utcnow().date().isoformat()
    return {"total_doors": total, "locked": locked, "unlocked": total - locked,
            "online": online, "offline": total - online,
            "events_today": sum(1 for l in ACCESS_LOGS if l["timestamp"].startswith(today)),
            "security_score": round(locked / total * 100, 1)}


@app.websocket("/ws/events")
async def ws_handler(ws: WebSocket):
    await ws.accept()
    connected_ws.append(ws)
    active_websockets.set(len(connected_ws))
    try:
        await ws.send_text(json.dumps({"type": "connected", "doors": DOORS_DB}))
        while True:
            await asyncio.wait_for(ws.receive_text(), timeout=30)
    except (WebSocketDisconnect, asyncio.TimeoutError):
        pass
    finally:
        if ws in connected_ws: connected_ws.remove(ws)
        active_websockets.set(len(connected_ws))
