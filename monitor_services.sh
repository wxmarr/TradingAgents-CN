#!/usr/bin/env bash
# ============================================================
# TradingAgents-CN 服务健康监控 + 自动拉起脚本
# 监控: MongoDB / Redis / 后端(8000) / 前端(3000)
# 用法:
#   ./monitor_services.sh          执行一次检查（异常自动拉起）
#   ./monitor_services.sh --loop   持续监控（每 30 秒一轮）
#   ./monitor_services.sh --status 只查看状态，不拉起
# ============================================================
set -u

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

REDIS_PW=$(grep -E '^REDIS_PASSWORD=' "$PROJECT_DIR/.env" | cut -d= -f2- | tr -d ' \r')
REDIS_PORT="${REDIS_PORT:-6379}"
BACKEND_PORT="${BACKEND_PORT:-8000}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
LOG_DIR="$PROJECT_DIR/logs"
MONITOR_LOG="$LOG_DIR/monitor.log"

mkdir -p "$LOG_DIR"

log() { printf '%s [monitor] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$MONITOR_LOG"; }

port_open() { nc -z -G 2 "127.0.0.1" "$1" >/dev/null 2>&1; }
http_ok()   { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$1/" 2>/dev/null)" = "200" ]; }

# 检查单个服务，返回 0=正常 1=异常
check_mongodb()   { port_open "$MONGO_PORT"; }
check_redis()     { port_open "$REDIS_PORT"; }
check_backend()   { port_open "$BACKEND_PORT"; }
check_frontend()  { port_open "$FRONTEND_PORT"; }

MONGO_PORT=27017

# ---------- 拉起函数 ----------
start_mongodb() {
  log "拉起 MongoDB (brew services)..."
  if brew services start mongodb-community >/dev/null 2>&1; then
    log "✅ MongoDB 已通过 brew services 启动"
  else
    log "⚠️  brew services 启动失败，尝试直接启动 mongod..."
    mongod --config /opt/homebrew/etc/mongod.conf --fork >/dev/null 2>&1
    log "MongoDB 直接启动 (fork)"
  fi
}

start_redis() {
  log "拉起 Redis (端口 $REDIS_PORT)..."
  if [ -n "$REDIS_PW" ]; then
    redis-server --port "$REDIS_PORT" --requirepass "$REDIS_PW" --daemonize yes \
      --logfile "$LOG_DIR/redis.log" >/dev/null 2>&1
  else
    redis-server --port "$REDIS_PORT" --daemonize yes \
      --logfile "$LOG_DIR/redis.log" >/dev/null 2>&1
  fi
  log "✅ Redis 已启动"
}

start_backend() {
  log "拉起后端 (端口 $BACKEND_PORT)..."
  # 先清理可能残留的失效进程
  lsof -ti:"$BACKEND_PORT" 2>/dev/null | xargs kill -9 2>/dev/null
  sleep 1
  # 后台启动 start_dev.py（同时拉起 Backend + Worker）
  nohup python3 start_dev.py >> "$LOG_DIR/backend.log" 2>&1 &
  log "✅ 后端启动命令已提交"
}

start_frontend() {
  log "拉起前端 (端口 $FRONTEND_PORT)..."
  lsof -ti:"$FRONTEND_PORT" 2>/dev/null | xargs kill -9 2>/dev/null
  sleep 1
  ( cd "$PROJECT_DIR/frontend" && nohup npm run dev >> "$LOG_DIR/frontend.log" 2>&1 & )
  log "✅ 前端启动命令已提交"
}

# ---------- 单次检查并拉起 ----------
run_once() {
  local repaired=0

  if check_mongodb; then
    log "✅ MongoDB    正常 (端口 $MONGO_PORT)"
  else
    log "❌ MongoDB    异常，尝试拉起..."
    start_mongodb
    repaired=1
  fi

  if check_redis; then
    log "✅ Redis      正常 (端口 $REDIS_PORT)"
  else
    log "❌ Redis      异常，尝试拉起..."
    start_redis
    repaired=1
  fi

  if check_backend; then
    log "✅ 后端       正常 (端口 $BACKEND_PORT)"
  else
    log "❌ 后端       异常，尝试拉起..."
    start_backend
    repaired=1
  fi

  if check_frontend; then
    log "✅ 前端       正常 (端口 $FRONTEND_PORT)"
  else
    log "❌ 前端       异常，尝试拉起..."
    start_frontend
    repaired=1
  fi

  if [ "$repaired" = "1" ]; then
    log "🔄 已触发拉起，等待 15 秒后复检..."
    sleep 15
    log "--- 复检结果 ---"
    check_mongodb   && log "✅ MongoDB    恢复" || log "❌ MongoDB    仍异常"
    check_redis     && log "✅ Redis      恢复" || log "❌ Redis      仍异常"
    check_backend   && log "✅ 后端       恢复" || log "❌ 后端       仍异常"
    check_frontend  && log "✅ 前端       恢复" || log "❌ 前端       仍异常"
  fi
}

# ---------- 主逻辑 ----------
case "${1:-}" in
  --status)
    echo "===== 服务状态 ====="
    check_mongodb   && echo "✅ MongoDB    (27017)"  || echo "❌ MongoDB    (27017)"
    check_redis     && echo "✅ Redis      ($REDIS_PORT)" || echo "❌ Redis      ($REDIS_PORT)"
    check_backend   && echo "✅ 后端       ($BACKEND_PORT)"  || echo "❌ 后端       ($BACKEND_PORT)"
    check_frontend  && echo "✅ 前端       ($FRONTEND_PORT)"  || echo "❌ 前端       ($FRONTEND_PORT)"
    ;;
  --loop)
    log "========== 启动持续监控 (每 30 秒一轮) =========="
    while true; do
      run_once
      sleep 30
    done
    ;;
  *)
    log "========== 单次检查 =========="
    run_once
    ;;
esac
