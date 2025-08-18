from flask import Flask
import os

app = Flask(__name__)
APP_VERSION = os.getenv("APP_VERSION", "Final Version-Final-v3")

@app.get("/")
def root():
    return f"Hello from Flask on DOKS {APP_VERSION}!\n"

@app.get("/healthz")
def healthz():
    return "ok\n"

if __name__ == "__main__":
    port = int(os.getenv("PORT", "8080"))
    app.run(host="0.0.0.0", port=port)
