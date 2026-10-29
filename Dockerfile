# Eugene Rings 웹 배포용 이미지 (사내 서버·클라우드 공통)
FROM python:3.12-slim
WORKDIR /app
COPY server/requirements.txt server/requirements.txt
RUN pip install --no-cache-dir -r server/requirements.txt
COPY index.html sample-*.jpg ./
COPY server ./server
ENV PORT=8000
EXPOSE 8000
# ANTHROPIC_API_KEY 는 이미지에 넣지 않고 실행할 때 환경변수로 넘긴다
CMD ["sh", "-c", "uvicorn server.main:app --host 0.0.0.0 --port ${PORT}"]
