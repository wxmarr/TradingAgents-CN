#!/usr/bin/env bash
# ============================================================
# TradingAgents-CN 一键启动脚本
# 用法: ./start.sh            启动 MongoDB + Redis + uvicorn (前台, Ctrl+C 停止)
#       ./start.sh --db-only  只启动数据库, 不启动后端
# ============================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

MONGO_BIN="$(command -v mongod || true)"
REDIS_BIN="$(command -v redis-server || true)"
REDIS_CLI="$(command -v redis-cli || true)"
REDIS_CONF="/opt/homebrew/etc/redis.conf"

MONGO_PORT=27017
REDIS_PORT=6379
APP_PORT="${APP_PORT:-8000}"

MONGO_DATA_DIR="$PROJECT_DIR/.mongodb-data"
MONGO_LOG="$PROJECT_DIR/.runtime/mongod.log"
REDIS_LOG="$PROJECT_DIR/.runtime/redis.log"

MODE="${1:-all}"

mkdir -p "$PROJECT_DIR/.runtime"

# 记录本脚本启动的进程 PID，退出时只清理这些
STARTED_PIDS=()

log() { printf '\033[1;36m[setup]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ err]\033[0m %s\n' "$*"; }

port_in_use() {
  nc -z -G 2 "127.0.0.1" "$1" >/dev/null 2>&1
}

cleanup() {
  log "收到退出信号, 清理本脚本启动的进程..."
  for pid in "${STARTED_PIDS[@]:-}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
  # 只清理后端端口(8000), 不动 MongoDB/Redis 已存在的实例
  log "清理完成."
}
trap cleanup EXIT INT TERM

# ---------- 依赖检查 ----------
log "检查依赖..."
[ -n "$MONGO_BIN" ] || { err "未找到 mongod, 请先 brew install mongodb-community"; exit 1; }
[ -n "$REDIS_BIN" ] || { err "未找到 redis-server, 请先 brew install redis"; exit 1; }
ok "mongod: $MONGO_BIN"
ok "redis-server: $REDIS_BIN"

# ---------- 启动 MongoDB ----------
log "处理 MongoDB (端口 $MONGO_PORT)..."
if port_in_use "$MONGO_PORT"; then
  ok "MongoDB 已在运行, 跳过"
else
  mkdir -p "$MONGO_DATA_DIR"
  log "启动 MongoDB..."
  "$MONGO_BIN" --dbpath "$MONGO_DATA_DIR" \
    --bind_ip 127.0.0.1 \
    --port "$MONGO_PORT" \
    --logpath "$MONGO_LOG" \
    >/dev/null 2>&1 &
  STARTED_PIDS+=("$!")
  for _ in $(seq 1 15); do
    port_in_use "$MONGO_PORT" && break
    sleep 1
  done
  if port_in_use "$MONGO_PORT"; then
    ok "MongoDB 已就绪"
  else
    err "MongoDB 启动失败, 日志: $MONGO_LOG"
    exit 1
  fi
fi

# ---------- 启动 Redis ----------
log "处理 Redis (端口 $REDIS_PORT)..."
if port_in_use "$REDIS_PORT"; then
  ok "Redis 已在运行, 跳过"
else
  if [ -f "$REDIS_CONF" ]; then
    log "启动 Redis (使用配置 $REDIS_CONF)..."
    "$REDIS_BIN" "$REDIS_CONF" > "$REDIS_LOG" 2>&1 &
    STARTED_PIDS+=("$!")
  else
    REDIS_PW=$(grep -E '^REDIS_PASSWORD=' "$PROJECT_DIR/.env" | cut -d= -f2- | tr -d ' ')
    log "启动 Redis (密码模式)..."
    "$REDIS_BIN" --port "$REDIS_PORT" --requirepass "$REDIS_PW" > "$REDIS_LOG" 2>&1 &
    STARTED_PIDS+=("$!")
  fi
  for _ in $(seq 1 15); do
    port_in_use "$REDIS_PORT" && break
    sleep 1
  done
  if port_in_use "$REDIS_PORT"; then
    ok "Redis 已就绪"
  else
    err "Redis 启动失败, 日志: $REDIS_LOG"
    exit 1
  fi
fi

# 验证 Redis 认证
REDIS_PW=$(grep -E '^REDIS_PASSWORD=' "$PROJECT_DIR/.env" | cut -d= -f2- | tr -d ' ')
if [ -n "$REDIS_CLI" ] && [ -n "$REDIS_PW" ]; then
  if "$REDIS_CLI" -h 127.0.0.1 -p "$REDIS_PORT" -a "$REDIS_PW" --no-auth-warning ping 2>/dev/null | grep -q PONG; then
    ok "Redis 认证通过"
  else
    warn "Redis 认证未通过 (可能使用 ACL 用户而非 default)"
  fi
fi

# ---------- 启动后端 ----------
if [ "$MODE" = "--db-only" ]; then
  log "仅数据库模式, 后端未启动. 按 Ctrl+C 退出."
  while true; do sleep 3600; done
fi

log "处理后端 (端口 $APP_PORT)..."
if port_in_use "$APP_PORT"; then
  warn "端口 $APP_PORT 已被占用, 清理中..."
  lsof -ti:"$APP_PORT" | xargs kill -9 2>/dev/null || true
  sleep 1
fi

export PROJECT_CONFIG_DIR="$PROJECT_DIR/.runtime/config"

log "启动 uvicorn (http://127.0.0.1:$APP_PORT)..."
exec .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port "$APP_PORT" --reload
