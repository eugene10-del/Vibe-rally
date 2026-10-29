# Eugene Rings · 웹 배포용 FastAPI 서버 (시연용 가상 데이터)
# 화면(index.html)과 AI 답변 주소(/api/ai)를 한 서버에서 제공한다.
# 실행: pip install -r server/requirements.txt  →  uvicorn server.main:app --host 0.0.0.0 --port 8000
# 키: ANTHROPIC_API_KEY 환경변수. 키는 서버 안에만 있고 화면(브라우저)에는 절대 보내지 않는다.
import json
import os
import re
import time
from collections import defaultdict, deque
from pathlib import Path

import anthropic
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel

ROOT = Path(__file__).resolve().parent.parent
MODEL = os.getenv("CLAUDE_MODEL", "claude-opus-5-5")
EFFORT = {"quick": "low", "default": "medium", "complex": "high"}
# 공개 URL 사용량 제한: 접속자(IP)별 1분 최대 횟수, 서버 전체 하루 최대 횟수
PER_MIN = int(os.getenv("AI_PER_MINUTE", "12"))
PER_DAY = int(os.getenv("AI_PER_DAY", "2000"))
MAX_INPUT = 60_000  # 질문+자료 최대 글자 수
STATIC = {".html", ".jpg", ".jpeg", ".png", ".webp", ".svg", ".ico"}

app = FastAPI(title="Eugene Rings (demo)", docs_url=None, redoc_url=None)
client = anthropic.Anthropic()
hits: dict[str, deque] = defaultdict(deque)
day = {"date": "", "count": 0}


class Img(BaseModel):
    media_type: str
    data: str  # base64


class AiReq(BaseModel):
    input: str | list[dict]
    json_mode: bool = False
    tier: str = "default"
    images: list[Img] = []


def check_limit(ip: str):
    now, today = time.time(), time.strftime("%Y-%m-%d")
    if day["date"] != today:
        day.update(date=today, count=0)
    if day["count"] >= PER_DAY:
        raise HTTPException(429, {"code": "rate_limited", "message": "daily"})
    q = hits[ip]
    while q and now - q[0] > 60:
        q.popleft()
    if len(q) >= PER_MIN:
        raise HTTPException(429, {"code": "rate_limited", "message": "minute"})
    q.append(now)
    day["count"] += 1


def to_messages(req: AiReq) -> list[dict]:
    turns = [{"role": "user", "content": req.input}] if isinstance(req.input, str) else [{"role": t["role"], "content": str(t["content"])} for t in req.input]
    if sum(len(str(t["content"])) for t in turns) > MAX_INPUT:
        raise HTTPException(413, {"code": "prompt_too_large"})
    last = turns[-1]
    if req.json_mode:
        last["content"] += "\n\n답변은 JSON 값 하나로만 쓰세요. 다른 글은 쓰지 마세요."
    if req.images:
        last["content"] = [{"type": "image", "source": {"type": "base64", "media_type": i.media_type, "data": i.data}} for i in req.images[:4]] + [{"type": "text", "text": last["content"]}]
    return turns


def parse_json(text: str):
    try:
        return json.loads(text)
    except ValueError:
        m = re.search(r"[\[{].*[\]}]", text, re.S)
        if not m:
            raise HTTPException(422, {"code": "invalid_json", "text": text})
        return json.loads(m.group(0))


@app.get("/api/health")
def health():
    return {"ok": True, "model": MODEL}


@app.post("/api/ai")
def ai(req: AiReq, request: Request):
    check_limit(request.headers.get("x-forwarded-for", request.client.host if request.client else "?").split(",")[0].strip())
    try:
        res = client.beta.messages.create(
            model=MODEL,
            max_tokens=16000,
            output_config={"effort": EFFORT.get(req.tier, "medium")},
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
            messages=to_messages(req),
        )
    except anthropic.RateLimitError:
        raise HTTPException(429, {"code": "rate_limited"})
    except anthropic.APIStatusError as e:
        raise HTTPException(502, {"code": "upstream_error", "message": e.message})
    except anthropic.APIConnectionError:
        raise HTTPException(502, {"code": "upstream_error", "message": "connection"})
    if res.stop_reason == "refusal":
        raise HTTPException(422, {"code": "refused"})
    text = "".join(b.text for b in res.content if b.type == "text").strip()
    if not text:
        raise HTTPException(502, {"code": "empty_completion"})
    out = {"text": text, "truncated": res.stop_reason == "max_tokens"}
    if req.json_mode:
        out["json"] = parse_json(text)
    return out


@app.get("/")
def index():
    return FileResponse(ROOT / "index.html")


@app.get("/{path:path}")
def static_file(path: str):
    f = (ROOT / path).resolve()
    # 프로젝트 폴더 밖이나 서버 코드·설정 파일은 내보내지 않음
    if ROOT in f.parents and f.suffix.lower() in STATIC and f.is_file() and "server" not in f.parts and "context" not in f.parts:
        return FileResponse(f)
    raise HTTPException(404)
