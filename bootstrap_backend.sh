
#!/bin/bash
set -e

echo "🚀 Bootstrapping AutoPreLimTitleAPP backend..."

ROOT_DIR="AutoPreLimTitleAPP"

mkdir -p "$ROOT_DIR"
cd "$ROOT_DIR"

# --- FOLDERS ---
mkdir -p app
mkdir -p app/api app/api/v1
mkdir -p app/core
mkdir -p app/schemas
mkdir -p app/services
mkdir -p app/repositories
mkdir -p app/workers
mkdir -p app/orchestrator
mkdir -p app/watchdog
mkdir -p app/normalization
mkdir -p app/pdf
mkdir -p config
mkdir -p docker

# --- app/__init__.py ---
cat > app/__init__.py << 'EOF'
# AutoPreLimTitleAPP backend package
EOF

# --- app/main.py ---
cat > app/main.py << 'EOF'
from fastapi import FastAPI
from app.api.router import api_router
from app.core.logging import setup_logging
from app.core.errors import register_error_handlers

def create_app() -> FastAPI:
    setup_logging()
    app = FastAPI(
        title="AutoPreLimTitleAPP",
        version="1.0.0",
    )
    app.include_router(api_router, prefix="/api")
    register_error_handlers(app)
    return app

app = create_app()
EOF

# --- app/config.py ---
cat > app/config.py << 'EOF'
from pydantic import BaseSettings

class Settings(BaseSettings):
    database_url: str
    redis_url: str = "redis://redis:6379/0"
    environment: str = "production"

    class Config:
        env_file = ".env"

settings = Settings()
EOF

# --- app/database.py ---
cat > app/database.py << 'EOF'
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, declarative_base
from app.config import settings

engine = create_engine(settings.database_url, future=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)
Base = declarative_base()

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
EOF

# --- app/celery_app.py ---
cat > app/celery_app.py << 'EOF'
from celery import Celery
from app.config import settings

celery_app = Celery(
    "title_search",
    broker=settings.redis_url,
    backend=settings.redis_url,
)

celery_app.conf.update(
    task_routes={
        "app.workers.tasks.run_title_search": {"queue": "title_search"},
    },
    task_serializer="json",
    result_serializer="json",
    accept_content=["json"],
)
EOF

# --- app/core/logging.py ---
mkdir -p app/core
cat > app/core/logging.py << 'EOF'
import logging

def setup_logging():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    )
EOF

# --- app/core/errors.py ---
cat > app/core/errors.py << 'EOF'
from fastapi import Request
from fastapi.responses import JSONResponse

def register_error_handlers(app):
    @app.exception_handler(Exception)
    async def generic_exception_handler(request: Request, exc: Exception):
        return JSONResponse(
            status_code=500,
            content={"detail": "Internal server error"},
        )
EOF

# --- app/api/__init__.py ---
cat > app/api/__init__.py << 'EOF'
# API package
EOF

# --- app/api/router.py ---
cat > app/api/router.py << 'EOF'
from fastapi import APIRouter
from app.api.v1.orders import router as orders_router
from app.api.v1.reports import router as reports_router
from app.api.v1.watchdog import router as watchdog_router

api_router = APIRouter()
api_router.include_router(orders_router, prefix="/v1/orders", tags=["orders"])
api_router.include_router(reports_router, prefix="/v1/reports", tags=["reports"])
api_router.include_router(watchdog_router, prefix="/v1/watchdog", tags=["watchdog"])
EOF

# --- app/api/v1/__init__.py ---
cat > app/api/v1/__init__.py << 'EOF'
# v1 API package
EOF

# --- app/api/v1/orders.py ---
cat > app/api/v1/orders.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.database import get_db
from app.schemas.orders import OrderCreate, OrderStatus, NormalizedReport
from app.services.orders_service import OrdersService
from app.workers.tasks import run_title_search_task

router = APIRouter()

@router.post("/", response_model=OrderStatus, status_code=status.HTTP_201_CREATED)
def create_order(payload: OrderCreate, db: Session = Depends(get_db)):
    service = OrdersService(db)
    status_obj = service.create_order(payload)
    run_title_search_task.delay(payload.dict())
    return status_obj

@router.get("/{order_id}/status", response_model=OrderStatus)
def get_order_status(order_id: str, db: Session = Depends(get_db)):
    service = OrdersService(db)
    status_obj = service.get_status(order_id)
    if not status_obj:
        raise HTTPException(status_code=404, detail="Order not found")
    return status_obj

@router.get("/{order_id}/normalized", response_model=NormalizedReport)
def get_normalized_report(order_id: str, db: Session = Depends(get_db)):
    service = OrdersService(db)
    report = service.get_normalized_report(order_id)
    if not report:
        raise HTTPException(status_code=404, detail="Report not available yet")
    return report
EOF

# --- app/api/v1/reports.py ---
cat > app/api/v1/reports.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.database import get_db
from app.schemas.reports import ReportMetadata
from app.services.reports_service import ReportsService

router = APIRouter()

@router.get("/{order_id}", response_model=ReportMetadata)
def get_report(order_id: str, db: Session = Depends(get_db)):
    service = ReportsService(db)
    meta = service.get_report_metadata(order_id)
    if not meta:
        raise HTTPException(status_code=404, detail="Report not found")
    return meta
EOF

# --- app/api/v1/watchdog.py ---
cat > app/api/v1/watchdog.py << 'EOF'
from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.database import get_db
from app.schemas.watchdog import PortalHealth
from app.services.watchdog_service import WatchdogService

router = APIRouter()

@router.get("/health", response_model=list[PortalHealth])
def list_portal_health(db: Session = Depends(get_db)):
    service = WatchdogService(db)
    return service.list_portal_health()
EOF

# --- app/schemas/__init__.py ---
cat > app/schemas/__init__.py << 'EOF'
# Pydantic schemas
EOF

# --- app/schemas/orders.py ---
cat > app/schemas/orders.py << 'EOF'
from datetime import datetime
from typing import Optional, List
from pydantic import BaseModel

class OrderCreate(BaseModel):
    property_address: str
    county: str
    customer_email: str
    rush: bool = False

class OrderStatus(BaseModel):
    id: str
    status: str
    created_at: datetime
    updated_at: datetime
    county: str
    error_message: Optional[str] = None

class Lien(BaseModel):
    type: str
    amount: Optional[float] = None
    holder: Optional[str] = None

class NormalizedReport(BaseModel):
    propertyAddress: str
    ownerName: Optional[str] = None
    parcelNumber: Optional[str] = None
    legalDescription: Optional[str] = None
    taxInfo: Optional[dict] = None
    liens: List[Lien] = []
    redFlags: List[str] = []
EOF

# --- app/schemas/reports.py ---
cat > app/schemas/reports.py << 'EOF'
from pydantic import BaseModel

class ReportMetadata(BaseModel):
    order_id: str
    county: str
    status: str
    pdf_url: str
EOF

# --- app/schemas/watchdog.py ---
cat > app/schemas/watchdog.py << 'EOF'
from datetime import datetime
from typing import Optional
from pydantic import BaseModel

class PortalHealth(BaseModel):
    portal_name: str
    status: str
    last_checked_at: datetime
    last_error: Optional[str] = None
EOF

# --- app/services/__init__.py ---
cat > app/services/__init__.py << 'EOF'
# Service layer
EOF

# --- app/services/orders_service.py ---
cat > app/services/orders_service.py << 'EOF'
from typing import Optional
from sqlalchemy.orm import Session
from app.schemas.orders import OrderCreate, OrderStatus, NormalizedReport
from app.repositories.orders_repo import OrdersRepository

class OrdersService:
    def __init__(self, db: Session):
        self.repo = OrdersRepository(db)

    def create_order(self, payload: OrderCreate) -> OrderStatus:
        order = self.repo.create_order(payload)
        return OrderStatus(
            id=order.id,
            status=order.status,
            created_at=order.created_at,
            updated_at=order.updated_at,
            county=order.county,
        )

    def get_status(self, order_id: str) -> Optional[OrderStatus]:
        order = self.repo.get_order(order_id)
        if not order:
            return None
        return OrderStatus(
            id=order.id,
            status=order.status,
            created_at=order.created_at,
            updated_at=order.updated_at,
            county=order.county,
            error_message=order.error_message,
        )

    def get_normalized_report(self, order_id: str) -> Optional[NormalizedReport]:
        return self.repo.get_normalized_report(order_id)
EOF

# --- app/services/reports_service.py ---
cat > app/services/reports_service.py << 'EOF'
from typing import Optional
from sqlalchemy.orm import Session
from app.schemas.reports import ReportMetadata
from app.repositories.orders_repo import OrdersRepository

class ReportsService:
    def __init__(self, db: Session):
        self.repo = OrdersRepository(db)

    def get_report_metadata(self, order_id: str) -> Optional[ReportMetadata]:
        report = self.repo.get_report_record(order_id)
        if not report:
            return None
        return ReportMetadata(
            order_id=order_id,
            county=report.county,
            status=report.status,
            pdf_url=report.pdf_url,
        )
EOF

# --- app/services/watchdog_service.py ---
cat > app/services/watchdog_service.py << 'EOF'
from typing import List
from sqlalchemy.orm import Session
from app.schemas.watchdog import PortalHealth
from app.repositories.watchdog_repo import WatchdogRepository

class WatchdogService:
    def __init__(self, db: Session):
        self.repo = WatchdogRepository(db)

    def list_portal_health(self) -> List[PortalHealth]:
        records = self.repo.get_all_portal_health()
        return [
            PortalHealth(
                portal_name=r.portal_name,
                status=r.status,
                last_checked_at=r.last_checked_at,
                last_error=r.last_error,
            )
            for r in records
        ]
EOF

# --- app/services/orchestrator_service.py ---
cat > app/services/orchestrator_service.py << 'EOF'
import json
from pathlib import Path
from typing import Dict, Any
from app.schemas.orders import OrderCreate, NormalizedReport, Lien

COUNTY_MAP_PATH = Path("config/counties.json")

def load_county_map() -> Dict[str, Dict[str, Any]]:
    with COUNTY_MAP_PATH.open() as f:
        return json.load(f)

class OrchestratorService:
    def __init__(self):
        self.counties = load_county_map()

    def resolve_county_profile(self, county: str) -> Dict[str, Any]:
        return self.counties.get(county, {"tier": 3, "automation": 0.0})

    def run_title_search(self, order: OrderCreate) -> NormalizedReport:
        profile = self.resolve_county_profile(order.county)
        tier = profile["tier"]
        automation_pct = profile["automation"]

        red_flags = []
        liens: list[Lien] = []

        if automation_pct >= 0.9:
            tax_info = {"year": 2024, "amountDue": 0.0, "paid": True}
        elif automation_pct >= 0.5:
            tax_info = {"year": 2024, "amountDue": None, "paid": None}
            red_flags.append("Partial automation: some data requires manual verification.")
        else:
            tax_info = None
            red_flags.append("County is not fully automated. Manual review required.")

        if automation_pct < 1.0:
            red_flags.append(
                f"Automation coverage for {order.county} is approximately {int(automation_pct * 100)}%. "
                "This report may require manual review."
            )

        return NormalizedReport(
            propertyAddress=order.property_address,
            ownerName=None,
            parcelNumber=None,
            legalDescription=None,
            taxInfo=tax_info,
            liens=liens,
            redFlags=red_flags,
        )
EOF

# --- app/repositories/__init__.py ---
cat > app/repositories/__init__.py << 'EOF'
# Repository layer
EOF

# --- app/repositories/orders_repo.py ---
cat > app/repositories/orders_repo.py << 'EOF'
from typing import Optional
from sqlalchemy.orm import Session
from app.schemas.orders import OrderCreate, NormalizedReport

class OrdersRepository:
    def __init__(self, db: Session):
        self.db = db

    def create_order(self, payload: OrderCreate):
        from datetime import datetime
        class Obj: pass
        o = Obj()
        o.id = "ord_123"
        o.status = "queued"
        o.created_at = datetime.utcnow()
        o.updated_at = o.created_at
        o.county = payload.county
        o.error_message = None
        return o

    def get_order(self, order_id: str):
        return None

    def save_normalized_report(self, order_id: str, report: NormalizedReport):
        pass

    def get_normalized_report(self, order_id: str) -> Optional[NormalizedReport]:
        return None

    def get_report_record(self, order_id: str):
        return None
EOF

# --- app/repositories/watchdog_repo.py ---
cat > app/repositories/watchdog_repo.py << 'EOF'
from sqlalchemy.orm import Session

class WatchdogRepository:
    def __init__(self, db: Session):
        self.db = db

    def get_all_portal_health(self):
        return []
EOF

# --- app/workers/__init__.py ---
cat > app/workers/__init__.py << 'EOF'
# Celery workers
EOF

# --- app/workers/tasks.py ---
cat > app/workers/tasks.py << 'EOF'
from app.celery_app import celery_app
from app.services.orchestrator_service import OrchestratorService
from app.schemas.orders import OrderCreate

orchestrator = OrchestratorService()

@celery_app.task(name="app.workers.tasks.run_title_search")
def run_title_search_task(order_data: dict):
    order = OrderCreate(**order_data)
    report = orchestrator.run_title_search(order)
    return report.dict()
EOF

# --- config/counties.json ---
cat > config/counties.json << 'EOF'
{
  "Lee": { "tier": 1, "automation": 0.95 },
  "Collier": { "tier": 1, "automation": 0.9 },
  "Miami-Dade": { "tier": 2, "automation": 0.7 },
  "Unknown": { "tier": 3, "automation": 0.2 }
}
EOF

# --- Dockerfile ---
cat > Dockerfile << 'EOF'
FROM python:3.11-slim

RUN apt-get update && apt-get install -y \
    build-essential \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY pyproject.toml poetry.lock* /app/ || true
RUN pip install --upgrade pip && pip install fastapi uvicorn[standard] sqlalchemy pydantic celery psycopg2-binary

COPY app /app/app
COPY config /app/config

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

# --- docker-compose.yml ---
cat > docker-compose.yml << 'EOF'
version: "3.9"

services:
  api:
    build: .
    container_name: title_api
    restart: always
    env_file: .env
    ports:
      - "8000:8000"
    depends_on:
      - db
      - redis
    volumes:
      - ./app:/app/app
      - ./config:/app/config

  worker:
    build: .
    container_name: title_worker
    restart: always
    env_file: .env
    command: ["celery", "-A", "app.celery_app.celery_app", "worker", "--loglevel=INFO"]
    depends_on:
      - redis
      - db

  redis:
    image: redis:7
    container_name: title_redis
    restart: always

  db:
    image: postgres:15
    container_name: title_db
    restart: always
    environment:
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASS}
      POSTGRES_DB: ${DB_NAME}
    volumes:
      - pgdata:/var/lib/postgresql/data
    ports:
      - "5432:5432"

volumes:
  pgdata:
EOF

# --- .env ---
cat > .env << 'EOF'
ENV=production
DB_USER=titleuser
DB_PASS=supersecretpassword
DB_NAME=titlesearch
DATABASE_URL=postgresql+psycopg2://titleuser:supersecretpassword@db:5432/titlesearch
REDIS_URL=redis://redis:6379/0
EOF

echo "✅ Backend scaffolded under $(pwd)"
