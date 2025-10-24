#!/bin/bash

# Kill existing processes on ports 8000 and 3000
echo "🔄 Killing existing processes on ports 8000 and 3000..."
kill -9 $(lsof -ti:8000) 2>/dev/null || true
kill -9 $(lsof -ti:3000) 2>/dev/null || true

echo "✅ Ports cleared"
echo ""

# Load backend environment variables (required for planner & resolver)
if [ -f CiFHErTradeArena-BE/.env ]; then
  set -a
  # shellcheck disable=SC1091
  source CiFHErTradeArena-BE/.env
  set +a
fi

# Start backend
echo "🚀 Starting backend server on port 8000..."
cd CiFHErTradeArena-BE
.venv/bin/python src/main.py &
BACKEND_PID=$!
cd ..

# Start frontend
echo "🚀 Starting frontend server on port 3000..."
cd CiFHErTradeArena-FE
bun run dev &
FRONTEND_PID=$!
cd ..

echo ""
echo "✅ Servers starting..."
echo "   Backend: http://0.0.0.0:8000 (PID: $BACKEND_PID)"
echo "   Frontend: http://localhost:3000 (PID: $FRONTEND_PID)"
echo ""
echo "Press Ctrl+C to stop both servers"

# Wait for background processes
wait
