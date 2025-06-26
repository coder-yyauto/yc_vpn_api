"""
Gunicorn配置文件 - VPN用户管理API
使用Unix Socket与NGINX代理通信
"""

import multiprocessing
import os

# 绑定地址 - 使用Unix Socket
bind = "unix:/dev/shm/vpn_users_api.socket"

# 工作进程数 - 根据CPU核心数自动设置
workers = multiprocessing.cpu_count() * 2 + 1
worker_class = "sync"  # 使用同步工作器，适合CPU密集型任务
worker_connections = 1000

# Socket文件权限设置
user = "pyuser"
group = "pyuser"
umask = 0

# 进程管理
preload_app = True  # 预加载应用以提高性能
max_requests = 1000  # 每个工作进程最大请求数后重启
max_requests_jitter = 50  # 添加随机抖动避免同时重启

# 超时设置
timeout = 60  # 请求超时时间
keepalive = 5  # Keep-Alive连接超时

# 日志配置
accesslog = "/home/pyuser/logs/gunicorn_access.log"
errorlog = "/home/pyuser/logs/gunicorn_error.log"
loglevel = "info"
access_log_format = '%(h)s %(l)s %(u)s %(t)s "%(r)s" %(s)s %(b)s "%(f)s" "%(a)s" %(D)s'

# 进程命名
proc_name = "vpn_users_api"

# 后台运行设置（systemd管理时设为False）
daemon = False

# 启动前钩子 - 确保日志目录存在
def on_starting(server):
    """服务启动前的钩子函数"""
    log_dir = "/home/pyuser/logs"
    if not os.path.exists(log_dir):
        os.makedirs(log_dir, mode=0o755, exist_ok=True)
        print(f"创建日志目录: {log_dir}")

# 工作进程启动后钩子
def when_ready(server):
    """服务就绪后的钩子函数"""
    print(f"VPN用户管理API服务已启动，监听: {bind}")
    print(f"工作进程数: {workers}")

# 工作进程退出钩子
def worker_int(worker):
    """工作进程中断钩子"""
    print(f"工作进程 {worker.pid} 收到中断信号")

def post_fork(server, worker):
    """工作进程fork后钩子"""
