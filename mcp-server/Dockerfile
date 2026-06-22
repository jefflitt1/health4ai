FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Set DATABASE_URL at runtime: docker run -e DATABASE_URL=postgresql://...
# Omitting it here forces an explicit runtime value (server fails fast if absent).

CMD ["python", "main.py"]
