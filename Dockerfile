FROM python:3.11-slim
WORKDIR /app
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ ./
ENV PORT=8080
# Do NOT set APP_VERSION here
EXPOSE 8080
CMD ["python", "app.py"]