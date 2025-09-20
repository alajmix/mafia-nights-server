# Mafia Nights Server (Vapor + WebSockets)

## Deploy to Render (no credit card)
1. Push this folder to GitHub:
   ```bash
   git init
   git add .
   git commit -m "initial"
   git branch -M main
   git remote add origin https://github.com/<YOUR-USER>/mafia-nights-server.git
   git push -u origin main
   ```
2. Go to https://render.com → **New** → **Blueprint** → paste your repo URL → choose **Free** → **Deploy**.
3. After deploy:
   - Health: `https://<your-host>.onrender.com/health` → `ok`
   - WebSocket: `wss://<your-host>.onrender.com/ws?room=ABCD12&name=YourName`

## Run locally (optional)
```bash
swift build
swift run
# then connect with ws://localhost:8080/ws?room=ABCD12&name=Abdullah
```
